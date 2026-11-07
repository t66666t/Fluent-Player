import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/transcript_scroll_motion.dart';
import 'package:video_player_app/widgets/ui_refresh_rate_scope.dart';

// Run on Android or a native desktop, with the engine driving every animation frame:
// flutter drive -d windows --profile
//   --driver=test_driver/subtitle_sidebar_scroll_driver.dart
//   --target=integration_test/subtitle_sidebar_reading_pace_test.dart
// Preferences and playback timestamps are synthetic; user media is untouched.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    // Native performance measurements must ignore tester-requested frames.
    // fullyLive mixes pump frames into vsync samples after an idle interval.
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  final reports = <Map<String, Object>>[];
  setUpAll(() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(
        'Transcript motion benchmark — automated test',
      );
      await windowManager.setMinimumSize(const Size(800, 820));
      await windowManager.setSize(const Size(800, 820));
      await windowManager.setResizable(false);
      await windowManager.focus();
    }
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
  });
  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets('$mode native short locates and consecutive follows', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': true,
        'subtitleViewMode': mode == 'list' ? 0 : 1,
        'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
        'subtitleArticleSentencesPerParagraph': 1,
        'landscapeSidebarLocatePositionPercent': 30,
      });
      await (SettingsService()..resetForTest()).init();
      final cues = List.generate(
        500,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 3),
          endTime: Duration(seconds: index * 3 + 3),
          text: 'Sentence $index, read the moving text. 字幕定位平滑起停。',
        ),
      );
      final player =
          VideoPlayerController.networkUrl(
              Uri.parse('https://example.invalid/reading-pace.mp4'),
            )
            ..value = const VideoPlayerValue(
              duration: Duration(hours: 1),
              position: Duration(minutes: 6),
              isInitialized: true,
            );
      final sidebar = GlobalKey<SubtitleSidebarState>();
      final timings = <ui.FrameTiming>[];
      final windows = <({int start, int end, Map<String, Object> report})>[];
      void collectTimings(List<ui.FrameTiming> batch) => timings.addAll(batch);
      binding.addTimingsCallback(collectTimings);
      var seeks = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => UiRefreshRateScope(child: child!),
          theme: appInteractionTheme(ThemeData(fontFamily: 'MiSans')),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 430,
                height: 720,
                child: SubtitleSidebar(
                  key: sidebar,
                  subtitles: cues,
                  controller: player,
                  onItemTap: (time) {
                    seeks++;
                    player.value = player.value.copyWith(position: time);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final list = find.byType(ScrollablePositionedList).first;
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      int itemFor(int cue) => mode == 'continuous'
          ? tester
                .widget<ContinuousArticleView>(
                  find.byType(ContinuousArticleView),
                )
                .layout
                .lineForSentence(cue)
          : cue;
      double leading(int cue) => tester
          .getTopLeft(
            find.descendant(
              of: list,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is IndexedSemantics && widget.index == itemFor(cue),
              ),
            ),
          )
          .dy;
      Offset textPoint(int cue) {
        for (final paragraph
            in tester.allRenderObjects.whereType<RenderParagraph>()) {
          final at = paragraph.text.toPlainText().indexOf('Sentence $cue,');
          if (at < 0 || !paragraph.hasSize) continue;
          for (final box in paragraph.getBoxesForSelection(
            TextSelection(baseOffset: at, extentOffset: at + 1),
          )) {
            final point = paragraph.localToGlobal(box.toRect().center);
            if (tester.getRect(list).contains(point)) return point;
          }
        }
        throw StateError('No visible text for cue $cue');
      }

      Future<void> reset() async {
        player.value = player.value.copyWith(
          position: cues[120].startTime,
          isPlaying: false,
        );
        await tester.pump();
        sidebar.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }

      try {
        await tester.pumpAndSettle();
        for (final auto in [false, true]) {
          for (final distance in [8.0, 20.0, 40.0, 80.0, 240.0, 360.0]) {
            await reset();
            final scroll = position();
            final delta =
                leading(121) -
                tester.getTopLeft(list).dy -
                scroll.viewportDimension * .3;
            scroll.jumpTo(scroll.pixels + delta - distance);
            await tester.pumpAndSettle();
            await Future<void>.delayed(const Duration(milliseconds: 800));
            final from = scroll.pixels;
            final initialViewport = scroll.viewportDimension;
            final initialDisplay =
                ui.PlatformDispatcher.instance.views.first.display;
            final initialDisplayId = initialDisplay.id;
            final initialHz = initialDisplay.refreshRate;
            final initialLeading = leading(121);
            final targetBox =
                find
                        .descendant(
                          of: list,
                          matching: find.byWidgetPredicate(
                            (widget) =>
                                widget is IndexedSemantics &&
                                widget.index == itemFor(121),
                          ),
                        )
                        .evaluate()
                        .single
                        .findRenderObject()!
                    as RenderBox;
            final beforeSeeks = seeks;
            final samples = <({int time, int wall, double pixels})>[];
            final inputStages = <Map<String, Object>>[];
            void markInput(String stage) => inputStages.add({
              'stage': stage,
              'wall': developer.Timeline.now,
              'rawFrame': binding.currentSystemFrameTimeStamp.inMicroseconds,
              'phase': binding.schedulerPhase.name,
            });
            var sampling = true;
            var visualError = 0.0;
            void sample(Duration time) {
              if (!sampling) return;
              samples.add((
                time: time.inMicroseconds,
                wall: developer.Timeline.now,
                pixels: scroll.pixels,
              ));
              visualError = math.max(
                visualError,
                (initialLeading -
                        targetBox.localToGlobal(Offset.zero).dy -
                        (scroll.pixels - from))
                    .abs(),
              );
              SchedulerBinding.instance.addPostFrameCallback(sample);
            }

            SchedulerBinding.instance.addPostFrameCallback(sample);
            final start = developer.Timeline.now;
            try {
              if (auto) {
                markInput('auto');
                player.value = player.value.copyWith(
                  position: cues[121].startTime,
                  isPlaying: true,
                );
              } else {
                markInput('beforePoint');
                final point = textPoint(121);
                markInput('beforeTap');
                final press = await tester.startGesture(
                  point,
                  kind: Platform.isAndroid || Platform.isIOS
                      ? PointerDeviceKind.touch
                      : PointerDeviceKind.mouse,
                );
                // A native mouse click spans frames. Keep the engine running
                // naturally between down and up, without tester.pump frames.
                await Future<void>.delayed(const Duration(milliseconds: 40));
                await press.up();
                markInput('afterTap');
              }
              final deadline = DateTime.now().add(const Duration(seconds: 2));
              while (DateTime.now().isBefore(deadline) &&
                  ((scroll.pixels - from).abs() < .01 ||
                      scroll.isScrollingNotifier.value)) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              expect(scroll.isScrollingNotifier.value, isFalse);
              expect(
                scroll.viewportDimension,
                initialViewport,
                reason: 'Native viewport changed during the measurement.',
              );
              expect(
                ui.PlatformDispatcher.instance.views.first.display.id,
                initialDisplayId,
                reason:
                    'Native test moved to another display during the measurement.',
              );
              expect(scroll.pixels, closeTo(from + distance, .01));
              expect(seeks - beforeSeeks, auto ? 0 : 1);
              final moving = samples
                  .where(
                    (s) =>
                        s.pixels > from + .01 &&
                        s.pixels < from + distance - .01,
                  )
                  .toList();
              expect(
                moving.length,
                greaterThanOrEqualTo(distance <= 20 ? 2 : 6),
              );
              final first = moving.first;
              final trajectory = TranscriptScrollMotion(
                from: from,
                to: from + distance,
                viewport: initialViewport,
                isAuto: auto,
              );
              // Recover the ticker phase from the first native position, then
              // check every later rendered frame against the continuous curve.
              // No assumption about regular VSync or test-pump timing is needed.
              var lower = 0.0, upper = trajectory.seconds;
              for (var i = 0; i < 50; i++) {
                final middle = (lower + upper) / 2;
                if (trajectory.x(middle) < first.pixels) {
                  lower = middle;
                } else {
                  upper = middle;
                }
              }
              final phase = (lower + upper) / 2;
              var error = 0.0;
              var previous = from;
              for (final value in moving) {
                final time = phase + (value.time - first.time) / 1e6;
                error = math.max(
                  error,
                  (value.pixels - trajectory.x(time)).abs(),
                );
                expect(value.pixels, greaterThanOrEqualTo(previous));
                previous = value.pixels;
              }
              final duration = trajectory.seconds;
              expect(error, lessThan(.05));
              expect(visualError, lessThan(.01));
              final report = <String, Object>{
                'mode': mode,
                'interactionTheme': 'production',
                'auto': auto,
                'distance': distance,
                'viewport': initialViewport,
                'displayId': initialDisplayId,
                'durationMs': duration * 1000,
                'averageSpeedPxPerSecond': distance / duration,
                'trajectoryErrorPx': error,
                'visualErrorPx': visualError,
                'nativeMovingFrames': moving.length,
                'displayHz': ui
                    .PlatformDispatcher
                    .instance
                    .views
                    .first
                    .display
                    .refreshRate,
              };
              reports.add(report);
              windows.add((
                start: start,
                end: developer.Timeline.now,
                report: report,
              ));
              binding.reportData = {'readingPace': reports};
              // ignore: avoid_print
              print('READING_PACE ${jsonEncode(report)}');
            } catch (error) {
              await Future<void>.delayed(const Duration(seconds: 1));
              // Preserve failed samples too: a missing frame must remain
              // distinguishable from a resized viewport or suppressed follow.
              // ignore: avoid_print
              print(
                'READING_FAILURE ${jsonEncode({
                  'mode': mode,
                  'auto': auto,
                  'distance': distance,
                  'viewportBefore': initialViewport,
                  'viewportAfter': scroll.viewportDimension,
                  'displayBefore': initialDisplayId,
                  'displayAfter': ui.PlatformDispatcher.instance.views.first.display.id,
                  'hzBefore': initialHz,
                  'hzAfter': ui.PlatformDispatcher.instance.views.first.display.refreshRate,
                  'hasSelection': sidebar.currentState!.hasTextSelection,
                  'lifecycle': binding.lifecycleState?.name,
                  'samples': samples.map((s) => {'time': s.time, 'wall': s.wall, 'pixels': s.pixels}).toList(),
                  'inputStages': inputStages,
                  'timings': timings.where((f) => f.timestampInMicroseconds(ui.FramePhase.buildStart) >= start).map((f) => {'start': f.timestampInMicroseconds(ui.FramePhase.vsyncStart), 'buildStart': f.timestampInMicroseconds(ui.FramePhase.buildStart), 'buildUs': f.buildDuration.inMicroseconds, 'rasterUs': f.rasterDuration.inMicroseconds, 'vsyncUs': f.vsyncOverhead.inMicroseconds}).toList(),
                })}',
              );
              rethrow;
            } finally {
              sampling = false;
            }
          }
        }

        await reset();
        final beforeSeeks = seeks;
        // New cues arrive before the previous line has finished moving.
        // Their motion must continue on one live viewport and finish at the
        // latest cue, without issuing playback seeks or retaining a fast move.
        for (var cue = 121; cue <= 126; cue++) {
          player.value = player.value.copyWith(
            position: cues[cue].startTime,
            isPlaying: true,
          );
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 220));
          expect(position().outOfRange, isFalse);
          expect(
            tester
                .widget<FadeTransition>(
                  find.byKey(const ValueKey('transcript-location-opacity')),
                )
                .opacity
                .value,
            1,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 750));
        expect(position().isScrollingNotifier.value, isFalse);
        expect(
          leading(126) - tester.getTopLeft(list).dy,
          closeTo(position().viewportDimension * .3, .1),
        );
        expect(seeks, beforeSeeks);
        // Timings arrive in batches; wait for the engine, then select only
        // frames inside actual locate windows (exclude fixture setup/reset).
        await Future<void>.delayed(const Duration(seconds: 1));
        double percentile(List<double> values, double p) {
          values.sort();
          return values[((values.length - 1) * p).round()];
        }

        for (final window in windows) {
          final frames = timings.where((f) {
            final time = f.timestampInMicroseconds(ui.FramePhase.buildStart);
            return time >= window.start && time < window.end;
          }).toList();
          expect(frames, isNotEmpty);
          final hz =
              ui.PlatformDispatcher.instance.views.first.display.refreshRate;
          final intervals = <double>[
            for (var i = 1; i < frames.length; i++)
              (frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
                      frames[i - 1].timestampInMicroseconds(
                        ui.FramePhase.vsyncStart,
                      )) /
                  1000,
          ];
          window.report.addAll({
            'timedFrames': frames.length,
            'buildP95Ms': percentile(
              frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
              .95,
            ),
            'rasterP95Ms': percentile(
              frames
                  .map((f) => f.rasterDuration.inMicroseconds / 1000)
                  .toList(),
              .95,
            ),
            'overBudgetFrames': frames
                .where(
                  (f) =>
                      f.buildDuration.inMicroseconds > 1e6 / hz ||
                      f.rasterDuration.inMicroseconds > 1e6 / hz,
                )
                .length,
            if (intervals.isNotEmpty)
              'frameIntervalP95Ms': percentile(intervals, .95),
          });
          // Report scheduling gaps separately from UI/raster work. A smooth
          // trajectory alone is not evidence of frames arriving on time.
          // ignore: avoid_print
          print('READING_FRAMES ${jsonEncode(window.report)}');
        }
      } finally {
        binding.removeTimingsCallback(collectTimings);
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      }
    });
  }
}
