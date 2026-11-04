import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/transcript_scroll_motion.dart';

void main() {
  for (final mode in ['list', 'paragraph', 'continuous']) {
    for (final size in [
      const Size(360, 480),
      const Size(760, 900),
      const Size(1280, 900),
    ]) {
      testWidgets('$mode reading motion adapts to $size', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final host = await _Host.create(tester, mode: mode, width: size.width);
        host.update(() => host.height = size.height);
        host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
        await tester.pumpAndSettle();
        final from = host.scrollable.position.pixels;
        host.sidebar.locateToTime(host.cues[123].startTime);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(host.scrollable.position.pixels, greaterThan(from));
        expect(host.scrollable.position.isScrollingNotifier.value, isTrue);
        host.expectOpaqueSingleList();
        await tester.pumpAndSettle();
        host.expectLocated(123);
        expect(host.scrollable.position.outOfRange, isFalse);
        await host.dispose();
      });
    }
    for (final hz in [60, 144]) {
      for (final auto in [false, true]) {
        for (final distance in [2.0, 8.0, 20.0, 40.0, 80.0, 240.0]) {
          testWidgets(
            '$mode Windows $hz Hz $distance px ${auto ? 'follow' : 'tap'} eases in and out',
            (tester) async {
              final host = await _Host.create(
                tester,
                mode: mode,
                platform: TargetPlatform.windows,
                followSeeks: true,
              );
              host.player.value = host.player.value.copyWith(
                position: host.cues[120].startTime,
              );
              host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
              await tester.pumpAndSettle();
              await tester.pump(const Duration(milliseconds: 700));
              final position = host.scrollable.position;
              final viewport = position.viewportDimension;
              final delta = (host.actualItemLeading(121) - .3) * viewport;
              position.jumpTo(position.pixels + delta - distance);
              await tester.pumpAndSettle();
              await tester.pump(const Duration(milliseconds: 700));
              final from = position.pixels;
              final initialVisual = host.actualItemLeading(121) * viewport;
              if (auto) {
                host.player.value = host.player.value.copyWith(
                  position: host.cues[121].startTime,
                  isPlaying: true,
                );
              } else {
                await tester.tapAt(
                  host.textPoint(121),
                  kind: PointerDeviceKind.mouse,
                );
              }
              await tester.pump(Duration.zero);
              await tester.pump(Duration.zero);
              final interval = Duration(microseconds: (1000000 / hz).round());
              await tester.pump(interval);
              var previous = position.pixels;
              final steps = <double>[];
              var movingFrames = 0;
              for (var frame = 0; frame < hz; frame++) {
                await tester.pump(interval);
                final current = position.pixels;
                expect(
                  initialVisual - host.actualItemLeading(121) * viewport,
                  closeTo(current - from, .005),
                );
                expect(current, inInclusiveRange(from, from + distance + .01));
                if (!position.isScrollingNotifier.value) break;
                final delta = current - previous;
                expect(delta, greaterThan(0));
                steps.add(delta);
                previous = current;
                movingFrames++;
                expect(host.readingOpacity, 1);
              }
              final movingSeconds =
                  movingFrames * interval.inMicroseconds / 1e6;
              // Check the actual scroll activity's pacing and soft endpoints.
              final expectedSeconds = TranscriptScrollMotion(
                from: from,
                to: from + distance,
                viewport: viewport,
                isAuto: auto,
              ).seconds;
              if (steps.length >= 6) {
                final peak = steps.reduce((a, b) => a > b ? a : b);
                expect(steps.first, lessThan(peak));
                expect(steps.last, lessThan(peak));
              }
              expect(
                movingSeconds,
                greaterThanOrEqualTo(
                  (expectedSeconds - 3 / hz).clamp(0.0, 1.0),
                ),
              );
              expect(movingSeconds, lessThan(expectedSeconds + 1 / hz));
              expect(position.isScrollingNotifier.value, isFalse);
              expect(position.pixels, closeTo(from + distance, .01));
              host.expectLocated(121);
              expect(host.seeks, auto ? 0 : 1);
              await host.dispose();
            },
          );
        }
      }
    }

    for (final hz in [60, 120, 144]) {
      for (final auto in [false, true]) {
        testWidgets(
          '$mode $hz Hz fifth cue ${auto ? 'follow' : 'tap'} has smooth movement',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(900, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final host = await _Host.create(
              tester,
              mode: mode,
              followSeeks: true,
            );
            host.update(() => host.height = 760);
            host.player.value = host.player.value.copyWith(
              position: host.cues[120].startTime,
            );
            host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
            await tester.pumpAndSettle();
            await tester.pump(const Duration(milliseconds: 700));
            final target = host.positionForSubtitle(125);
            expect(target.itemLeadingEdge, lessThan(1));
            expect(target.itemTrailingEdge, greaterThan(0));
            if (auto) {
              host.player.value = host.player.value.copyWith(
                position: host.cues[125].startTime,
                isPlaying: true,
              );
            } else {
              await tester.tapAt(host.textPoint(125));
            }
            await tester.pump(Duration.zero);
            await tester.pump(Duration.zero);
            final interval = Duration(microseconds: (1000000 / hz).round());
            // Auto-follow starts its ticker from a post-frame callback.
            await tester.pump(interval);
            var previous = host.scrollable.position.pixels;
            var previousVisual =
                host.actualItemLeading(125) *
                host.scrollable.position.viewportDimension;
            final steps = <double>[];
            for (var frame = 0; frame < 12; frame++) {
              await tester.pump(interval);
              final current = host.scrollable.position.pixels;
              final delta = current - previous;
              final visual =
                  host.actualItemLeading(125) *
                  host.scrollable.position.viewportDimension;
              expect(delta, greaterThan(0));
              expect(previousVisual - visual, closeTo(delta, .005));
              steps.add(delta);
              expect(host.readingOpacity, 1);
              previous = current;
              previousVisual = visual;
            }
            expect(
              steps.reduce((a, b) => a > b ? a : b),
              greaterThan(steps.first * 1.5),
            );
            await tester.pumpAndSettle();
            expect(host.seeks, auto ? 0 : 1);
            host.expectLocated(125);
            await host.dispose();
          },
        );
      }
    }

    testWidgets('$mode a deferred follow respects the auto-follow switch', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.player.value = host.player.value.copyWith(
        position: host.cues[120].startTime,
      );
      host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
      await tester.pumpAndSettle();
      host.player.value = host.player.value.copyWith(isPlaying: true);
      await tester.pump(const Duration(milliseconds: 16));
      host.player.value = host.player.value.copyWith(
        position: host.cues[121].startTime,
      );
      await tester.pump(const Duration(milliseconds: 16));
      final stopped = host.scrollable.position.pixels;
      await SettingsService().updateSetting('autoScrollSubtitles', false);
      await tester.pump(const Duration(milliseconds: 800));
      for (var frame = 0; frame < 80; frame++) {
        host.player.value = host.player.value.copyWith(
          position: host.cues[121].startTime + Duration(milliseconds: frame),
        );
        await tester.pump(const Duration(microseconds: 6944));
      }
      expect(host.scrollable.position.pixels, closeTo(stopped, .01));
      expect(host.seeks, 0);
      await host.dispose();
    });

    testWidgets(
      '$mode follow catches up when a cue changes during manual locate cooldown',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        host.player.value = host.player.value.copyWith(
          position: host.cues[120].startTime,
        );
        host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
        await tester.pumpAndSettle();
        host.player.value = host.player.value.copyWith(isPlaying: true);
        await tester.pump(const Duration(milliseconds: 16));
        host.player.value = host.player.value.copyWith(
          position: host.cues[121].startTime,
        );
        await tester.pump(const Duration(milliseconds: 16));
        // Older versions used wall-clock deadlines. Let both that deadline and
        // the scheduler's cooldown expire, then keep reporting the same cue.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)),
        );
        await tester.pump(const Duration(milliseconds: 800));
        for (var frame = 0; frame < 100; frame++) {
          host.player.value = host.player.value.copyWith(
            position: host.cues[121].startTime + Duration(milliseconds: frame),
          );
          await tester.pump(const Duration(microseconds: 6944));
        }
        host.expectLocated(121);
        host.expectOpaqueSingleList();
        await host.dispose();
      },
    );

    testWidgets(
      '$mode a long press during reading motion selects without seeking',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        final first = host.nearbySubtitle();
        host.sidebar.locateToTime(host.cues[first].startTime);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        await tester.longPressAt(host.textPoint(first - 1));
        await tester.pumpAndSettle();
        expect(host.seeks, 0);
        expect(host.sidebar.selectedTranscriptText, isNotEmpty);
        expect(host.scrollable.position.isScrollingNotifier.value, isFalse);
        await host.dispose();
      },
    );

    testWidgets(
      '$mode a drag during nearby motion takes over without seeking',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        host.sidebar.locateToTime(host.cues[host.nearbySubtitle()].startTime);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final before = host.scrollable.position.pixels;
        final gesture = await tester.startGesture(tester.getCenter(host.list));
        await gesture.moveBy(const Offset(0, -50));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -50));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(host.seeks, 0);
        expect(host.scrollable.position.pixels, greaterThan(before + 20));
        await host.dispose();
      },
    );

    testWidgets(
      '$mode interruption of the hidden boundary frame restores a usable viewport',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        host.sidebar.locateToTime(host.cues[299].startTime);
        await tester.pump();
        for (var frame = 0; frame < 40 && host.readingOpacity > 0; frame++) {
          await tester.pump(const Duration(milliseconds: 8));
        }
        expect(host.readingOpacity, 0);
        await tester.tapAt(tester.getCenter(host.list));
        await tester.pumpAndSettle();
        expect(host.seeks, 0);
        expect(host.readingOpacity, 1);
        expect(host.scrollable.position.outOfRange, isFalse);
        expect(host.isItemPainted(299), isTrue);
        await host.dispose();
      },
    );

    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      for (final elapsed in [24, 152]) {
        testWidgets(
          '$mode $kind a tap at ${elapsed}ms retargets the visible far-transition cue',
          (tester) async {
            final host = await _Host.create(
              tester,
              mode: mode,
              followSeeks: true,
              cueCount: 3000,
            );
            final sourceCue = host.nearbySubtitle();
            host.sidebar.locateToTime(host.cues[200].startTime);
            await tester.pump();
            for (var time = 0; time < elapsed; time += 8) {
              await tester.pump(const Duration(milliseconds: 8));
            }
            expect(host.readingOpacity, inExclusiveRange(0, 1));
            final clicked = elapsed < 70 ? sourceCue : 201;
            await tester.tapAt(host.textPoint(clicked), kind: kind);
            await tester.pump();
            expect(host.seeks, 1);
            expect(host.player.value.position, host.cues[clicked].startTime);
            expect(host.sidebar.selectedTranscriptText, isEmpty);
            await tester.pumpAndSettle();
            host.expectLocated(clicked);
            expect(host.readingOpacity, 1);
            await host.dispose();
          },
        );
      }

      testWidgets(
        '$mode $kind can tap a different cue during a nearby locate',
        (tester) async {
          final host = await _Host.create(
            tester,
            mode: mode,
            followSeeks: true,
            cueCount: 3000,
          );
          final first = host.nearbySubtitle();
          await tester.tapAt(host.textPoint(first), kind: kind);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(host.seeks, 1);
          expect(host.scrollable.position.isScrollingNotifier.value, isTrue);
          final next = first - 1;
          await tester.tapAt(host.textPoint(next), kind: kind);
          await tester.pump();
          expect(
            host.seeks,
            2,
            reason: 'The first tap during motion must seek too.',
          );
          expect(host.player.value.position, host.cues[next].startTime);
          expect(host.sidebar.selectedTranscriptText, isEmpty);
          await tester.pumpAndSettle();
          host.expectLocated(next);
          host.expectOpaqueSingleList();
          await host.dispose();
        },
      );
    }

    testWidgets(
      '$mode highlights only rebuild affected reading blocks in a long transcript',
      (tester) async {
        final host = await _Host.create(tester, mode: mode, cueCount: 5000);
        const previousCue = 2500;
        const nextCue = 2502;
        host.player.value = host.player.value.copyWith(
          position: host.cues[previousCue].startTime,
        );
        host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
        await tester.pumpAndSettle();
        final before = host.readingBlocks();
        expect(before.length, greaterThan(10));
        host.player.value = host.player.value.copyWith(
          position: host.cues[nextCue].startTime,
        );
        await tester.pump();
        final after = host.readingBlocks();
        final changed = before.keys
            .where(
              (index) =>
                  after.containsKey(index) &&
                  !identical(before[index], after[index]),
            )
            .toSet();
        final affected = mode == 'continuous'
            ? tester
                  .widget<ContinuousArticleView>(
                    find.byType(ContinuousArticleView),
                  )
                  .layout
                  .lines
                  .indexed
                  .where(
                    (entry) => entry.$2.sentenceIndices.any(
                      (index) => index == previousCue || index == nextCue,
                    ),
                  )
                  .map((entry) => entry.$1)
                  .toSet()
            : <int>{previousCue, nextCue};
        expect(changed, isNotEmpty);
        expect(
          changed.difference(affected),
          isEmpty,
          reason:
              'Only old/new cue blocks should rebuild, rather than ${changed.length}/${before.length} cached blocks.',
        );
        await host.dispose();
      },
    );

    testWidgets('$mode nearby locate accelerates gently from rest', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode, followSeeks: true);
      final subtitle = host.nearbySubtitle();
      await tester.tapAt(host.textPoint(subtitle));
      await tester.pump();
      expect(host.seeks, 1);
      expect(host.player.value.position, host.cues[subtitle].startTime);
      var previous = host.scrollable.position.pixels;
      final steps = <double>[];
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(microseconds: 6944));
        final current = host.scrollable.position.pixels;
        final delta = current - previous;
        expect(delta.abs(), greaterThan(0));
        steps.add(delta);
        previous = current;
      }
      expect(steps.last.abs(), greaterThan(steps.first.abs() * 2));
      await tester.pumpAndSettle();
      host.expectLocated(subtitle);
      await host.dispose();
    });

    for (final withTap in [false, true]) {
      testWidgets(
        '$mode same-direction ${withTap ? 'tap' : 'locate'} keeps moving when retargeted',
        (tester) async {
          final host = await _Host.create(
            tester,
            mode: mode,
            followSeeks: true,
          );
          host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
          await tester.pumpAndSettle();
          host.sidebar.locateToTime(host.cues[121].startTime);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          final before = host.scrollable.position.pixels;
          await tester.pump(const Duration(milliseconds: 8));
          final middle = host.scrollable.position.pixels;
          final previousStep = middle - before;
          expect(previousStep, greaterThan(.05));

          if (withTap) {
            await tester.tapAt(host.textPoint(122));
            expect(host.seeks, 1);
          } else {
            host.sidebar.locateToTime(host.cues[122].startTime);
          }
          await tester.pump();
          final restarted = host.scrollable.position.pixels;
          await tester.pump(const Duration(milliseconds: 8));
          final nextStep = host.scrollable.position.pixels - restarted;
          expect(
            nextStep,
            greaterThan(previousStep * .65),
            reason: 'A new target must not brake the text to zero and restart.',
          );
          await tester.pumpAndSettle();
          host.expectLocated(122);
          host.expectOpaqueSingleList();
          await host.dispose();
        },
      );
    }

    for (final withTap in [false, true]) {
      testWidgets(
        '$mode a visible half-page ${withTap ? 'tap' : 'locate'} scrolls without fading',
        (tester) async {
          final host = await _Host.create(tester, mode: mode);
          host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
          await tester.pumpAndSettle();
          final candidate = host.positions.firstWhere(
            (item) => item.itemLeadingEdge >= .78 && item.itemLeadingEdge < .98,
          );
          final target = mode == 'continuous'
              ? tester
                    .widget<ContinuousArticleView>(
                      find.byType(ContinuousArticleView),
                    )
                    .layout
                    .lines[candidate.index]
                    .sentenceIndices
                    .last
              : candidate.index;
          if (withTap) {
            await tester.tapAt(host.textPoint(target));
            expect(host.seeks, 1);
          } else {
            host.sidebar.locateToTime(host.cues[target].startTime);
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
          expect(host.readingOpacity, 1);
          expect(host.scrollable.position.isScrollingNotifier.value, isTrue);
          await tester.pumpAndSettle();
          host.expectLocated(target);
          host.expectOpaqueSingleList();
          await host.dispose();
        },
      );
    }

    testWidgets(
      '$mode a held tap stops motion and restarts gently on release',
      (tester) async {
        final host = await _Host.create(tester, mode: mode, followSeeks: true);
        host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
        await tester.pumpAndSettle();
        host.sidebar.locateToTime(host.cues[121].startTime);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final before = host.scrollable.position.pixels;
        await tester.pump(const Duration(milliseconds: 8));
        final previousStep = host.scrollable.position.pixels - before;
        final gesture = await tester.startGesture(host.textPoint(122));
        final stopped = host.scrollable.position.pixels;
        await tester.pump(const Duration(milliseconds: 180));
        expect(host.scrollable.position.pixels, stopped);
        await gesture.up(timeStamp: const Duration(milliseconds: 180));
        await tester.pump();
        expect(host.seeks, 1);
        final start = host.scrollable.position.pixels;
        await tester.pump(const Duration(milliseconds: 8));
        final firstStep = host.scrollable.position.pixels - start;
        expect(firstStep, greaterThan(0));
        expect(firstStep, lessThan(previousStep));
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          host.scrollable.position.pixels - start,
          greaterThan(firstStep * 2),
        );
        await tester.pumpAndSettle();
        host.expectLocated(122);
        await host.dispose();
      },
    );

    testWidgets('$mode repeated previous and next locates take over smoothly', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.sidebar.locateToTime(host.cues[120].startTime, animated: false);
      await tester.pumpAndSettle();
      for (final index in [121, 120, 122, 121]) {
        var previous = host.actualItemLeading(index);
        final direction = (.3 - previous).sign;
        host.sidebar.locateToTime(host.cues[index].startTime);
        await tester.pump();
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 8));
          final leading = host.actualItemLeading(index);
          expect((leading - previous) * direction, greaterThanOrEqualTo(-.002));
          expect((leading - previous).abs(), lessThan(.04));
          expect(find.byType(RawImage), findsNothing);
          previous = leading;
        }
      }
      await tester.pumpAndSettle();
      host.expectLocated(121);
      host.expectOpaqueSingleList();
      await host.dispose();
    });

    for (final percent in [0, 100]) {
      testWidgets(
        '$mode resume respects the $percent percent reading position',
        (tester) async {
          final host = await _Host.create(
            tester,
            mode: mode,
            locatePositionPercent: percent,
            skipInitialRepair: true,
          );
          const index = 120;
          host.player.value = host.player.value.copyWith(
            position: host.cues[index].startTime,
          );
          host.listWidget.itemScrollController!.jumpTo(
            index: host.itemForSubtitle(index),
            alignment: percent / 100,
          );
          await tester.pumpAndSettle();
          final destination = host.actualItemLeading(index);
          host.scrollable.position.jumpTo(
            host.scrollable.position.pixels + (percent == 0 ? 110 : -110),
          );
          await tester.pumpAndSettle();
          var previous = host.actualItemLeading(index);
          final direction = (destination - previous).sign;
          host.player.value = host.player.value.copyWith(isPlaying: true);
          for (var frame = 0; frame < 40; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            final leading = host.actualItemLeading(index);
            expect(
              (leading - previous) * direction,
              greaterThanOrEqualTo(-.002),
            );
            expect((leading - previous).abs(), lessThan(.08));
            expect(find.byType(RawImage), findsNothing);
            previous = leading;
          }
          expect(previous, closeTo(destination, .002));
          expect(host.scrollable.position.outOfRange, isFalse);
          await host.dispose();
        },
      );
    }

    testWidgets(
      '$mode reduced motion reveals cold end targets after clamping',
      (tester) async {
        final host = await _Host.create(
          tester,
          mode: mode,
          reducedMotion: true,
        );
        for (final index in [299, 0]) {
          host.player.value = host.player.value.copyWith(
            position: host.cues[index].startTime,
          );
          host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
          var shown = false;
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 8));
            if (!host.isItemPainted(index)) continue;
            shown = true;
            expect(host.scrollable.position.outOfRange, isFalse);
            expect(host.scrollable.position.isScrollingNotifier.value, isFalse);
          }
          expect(shown, isTrue);
          expect(find.byType(RawImage), findsNothing);
        }
        await host.dispose();
      },
    );

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final atBottom in [false, true]) {
        testWidgets(
          '$mode $platform resuming returns to the ${atBottom ? 'bottom' : 'top'} without a rebound',
          (tester) async {
            final host = await _Host.create(
              tester,
              mode: mode,
              platform: platform,
              skipInitialRepair: true,
            );
            final index = atBottom ? host.cues.length - 1 : 0;
            host.player.value = host.player.value.copyWith(
              position: host.cues[index].startTime,
            );
            host.listWidget.itemScrollController!.jumpTo(
              index: host.itemForSubtitle(index),
              alignment: .3,
            );
            await tester.pumpAndSettle();
            final destination = host.actualItemLeading(index);
            final browse = await tester.startGesture(
              tester.getCenter(host.list),
            );
            final browseDirection = atBottom ? 1.0 : -1.0;
            await browse.moveBy(Offset(0, browseDirection * 20));
            await tester.pump(const Duration(milliseconds: 40));
            await browse.moveBy(Offset(0, browseDirection * 110));
            await tester.pump(const Duration(milliseconds: 200));
            await browse.up();
            await tester.pumpAndSettle();
            final start = host.actualItemLeading(index);
            expect((start - destination).abs(), greaterThan(.1));
            host.player.value = host.player.value.copyWith(isPlaying: true);
            final samples = <double>[start];
            for (var frame = 0; frame < 75; frame++) {
              await tester.pump(const Duration(milliseconds: 8));
              samples.add(host.actualItemLeading(index));
            }
            final direction = (destination - start).sign;
            for (var i = 1; i < samples.length; i++) {
              expect(
                (samples[i] - samples[i - 1]) * direction,
                greaterThanOrEqualTo(-.002),
                reason:
                    'Playback return must not overshoot and spring back: $samples',
              );
            }
            expect(samples.last, closeTo(destination, .01));
            expect(host.scrollable.position.outOfRange, isFalse);
            expect(host.scrollable.position.isScrollingNotifier.value, isFalse);
            await host.dispose();
          },
        );

        testWidgets(
          '$mode $platform a distant return settles the ${atBottom ? 'bottom' : 'top'} before revealing it',
          (tester) async {
            final host = await _Host.create(
              tester,
              mode: mode,
              platform: platform,
              skipInitialRepair: true,
            );
            final index = atBottom ? host.cues.length - 1 : 0;
            final item = host.itemForSubtitle(index);
            host.player.value = host.player.value.copyWith(
              position: host.cues[index].startTime,
            );
            host.listWidget.itemScrollController!.jumpTo(
              index: item,
              alignment: .3,
            );
            await tester.pumpAndSettle();
            final destination = host.actualItemLeading(index);
            host.listWidget.itemScrollController!.jumpTo(
              index: host.itemForSubtitle(120),
              alignment: .3,
            );
            await tester.pumpAndSettle();
            host.player.value = host.player.value.copyWith(isPlaying: true);
            var destinationShown = false;
            for (var frame = 0; frame < 90; frame++) {
              await tester.pump(const Duration(milliseconds: 8));
              if (!host.positions.any((position) => position.index == item)) {
                continue;
              }
              if (!host.isItemPainted(index)) continue;
              destinationShown = true;
              expect(
                host.scrollable.position.outOfRange,
                isFalse,
                reason:
                    'An uncovered far destination must not still be springing back.',
              );
              expect(host.actualItemLeading(index), closeTo(destination, .002));
            }
            expect(destinationShown, isTrue);
            expect(host.scrollable.position.isScrollingNotifier.value, isFalse);
            await host.dispose();
          },
        );
      }
    }

    testWidgets('$mode far locate fades one live view without a long scroll', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.sidebar.locateToTime(host.cues[200].startTime);
      await tester.pump();
      await _frames(tester, 2);
      expect(host.readingOpacity, inExclusiveRange(0, 1));
      expect(
        host.positions.any((item) => item.index == host.itemForSubtitle(200)),
        isFalse,
      );
      expect(find.byType(RawImage), findsNothing);
      await _frames(tester, 6);
      host.expectLocated(200);
      final destination = host.positionForSubtitle(200).itemLeadingEdge;
      await _frames(tester, 5);
      expect(
        host.positionForSubtitle(200).itemLeadingEdge,
        closeTo(destination, .002),
        reason: 'The destination must not travel through screens of text.',
      );
      await tester.pumpAndSettle();
      expect(host.readingOpacity, 1);
      host.expectOpaqueSingleList();
      await host.dispose();
    });

    testWidgets('$mode hiding cancels an in-flight reading scroll', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode, following: false);
      final nearby = host.nearbySubtitle();
      host.sidebar.locateToTime(host.cues[nearby].startTime);
      await _frames(tester, 3);
      final stoppedOffset = host.scrollable.position.pixels;
      expect(host.scrollable.position.isScrollingNotifier.value, isTrue);

      host.update(() => host.visible = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      host.update(() => host.visible = true);
      await tester.pump();
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          host.scrollable.position.pixels,
          closeTo(stoppedOffset, .5),
          reason: 'Returning must not resume a ticker that was muted offstage.',
        );
      }
      await host.dispose();
    });

    testWidgets('$mode a newer repair cancels a pending far transition', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.sidebar.locateToTime(host.cues[200].startTime);
      host.player.value = host.player.value.copyWith(
        position: host.cues[120].startTime,
      );
      host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
      await tester.pumpAndSettle();
      host.expectLocated(120);
      host.expectOpaqueSingleList();
      expect(find.byType(RawImage), findsNothing);
      await host.dispose();
    });

    testWidgets(
      '$mode rapid distant requests retain a continuous painted view',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        host.sidebar.locateToTime(host.cues[200].startTime);
        await _frames(tester, 4);
        final opacity = host.readingOpacity;
        expect(opacity, inExclusiveRange(0, 1));
        host.sidebar.locateToTime(host.cues[120].startTime);
        await tester.pump();
        expect(
          host.readingOpacity,
          lessThanOrEqualTo(opacity + .001),
          reason:
              'Retargeting must not expose a bare intermediate destination.',
        );
        await tester.pumpAndSettle();
        host.expectLocated(120);
        host.expectOpaqueSingleList();
        await host.dispose();
      },
    );

    for (final following in [false, true]) {
      testWidgets('$mode route return is stable, following=$following', (
        tester,
      ) async {
        final host = await _Host.create(
          tester,
          mode: mode,
          following: following,
        );
        host.sidebar.locateToTime(host.cues[host.nearbySubtitle()].startTime);
        await _frames(tester, 3);
        final stoppedOffset = host.scrollable.position.pixels;
        final navigator = host.navigatorKey.currentState!;
        unawaited(
          navigator.push(
            PageRouteBuilder<void>(
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        if (following) {
          host.player.value = host.player.value.copyWith(
            position: host.cues[200].startTime,
          );
        }
        await tester.pump(const Duration(milliseconds: 400));
        navigator.pop();
        for (var frame = 0; frame < 18; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (following) {
            expect(
              host.paintedSubtitles().where((index) => index < 150),
              isEmpty,
            );
          } else {
            expect(host.scrollable.position.pixels, closeTo(stoppedOffset, .5));
          }
        }
        if (following) host.expectLocated(200);
        host.expectOpaqueSingleList();
        await host.dispose();
      });
    }

    for (final step in [8, 16]) {
      testWidgets('$mode nearby scroll is continuous at ${step}ms frames', (
        tester,
      ) async {
        final host = await _Host.create(tester, mode: mode);
        final subtitle = host.nearbySubtitle();
        final start = host.positionForSubtitle(subtitle).itemLeadingEdge;
        final direction = (.3 - start).sign;
        host.sidebar.locateToTime(host.cues[subtitle].startTime);
        var previous = start;
        for (var frame = 0; frame < (720 / step).ceil(); frame++) {
          await tester.pump(Duration(milliseconds: step));
          final leading = host.positionForSubtitle(subtitle).itemLeadingEdge;
          expect((leading - previous) * direction, greaterThanOrEqualTo(-.002));
          expect((leading - previous).abs(), lessThan(step * .01));
          expect(find.byType(RawImage), findsNothing);
          previous = leading;
        }
        host.expectLocated(subtitle);
        await host.dispose();
      });
    }

    testWidgets('$mode resize during a far transition preserves the target', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.sidebar.locateToTime(host.cues[200].startTime);
      await _frames(tester, 4);
      expect(host.readingOpacity, inExclusiveRange(0, 1));
      host.update(() => host.height = 300);
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNothing);
      host.expectLocated(200);
      host.expectOpaqueSingleList();
      await host.dispose();
    });

    testWidgets('$mode return paints the restored location on its first view', (
      tester,
    ) async {
      final host = await _Host.create(
        tester,
        mode: mode,
        preserveReading: true,
      );
      host.update(() => host.visible = false);
      await tester.pump();
      host.player.value = host.player.value.copyWith(
        position: host.cues[200].startTime,
      );
      await _frames(tester, 3);
      expect(host.viewportReady, isFalse);
      host.update(() => host.visible = true);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          host.paintedSubtitles().where((index) => index < 150),
          isEmpty,
          reason: 'Old content must not flash before the return repair lands.',
        );
      }
      host.expectLocated(200);
      expect(host.paintedSubtitles(), contains(200));
      expect(host.viewportReady, isTrue);
      await host.dispose();
    });

    testWidgets('$mode a pointer interrupts a fade and can immediately drag', (
      tester,
    ) async {
      final host = await _Host.create(tester, mode: mode);
      host.sidebar.locateToTime(host.cues[200].startTime);
      await _frames(tester, 4);
      expect(host.readingOpacity, inExclusiveRange(0, 1));
      final before = host.scrollable.position.pixels;
      final gesture = await tester.startGesture(tester.getCenter(host.list));
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(host.readingOpacity, 1);
      await gesture.moveBy(const Offset(0, -70));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(host.scrollable.position.pixels, greaterThan(before + 20));
      expect(host.seeks, 0);
      await host.dispose();
    });

    testWidgets(
      '$mode a completed old toggle cannot restore disabled following',
      (tester) async {
        final host = await _Host.create(tester, mode: mode, following: false);
        host.player.value = host.player.value.copyWith(
          position: host.cues[200].startTime,
        );
        await tester.pump();
        final toggle = tester.widget<InkWell>(
          find.descendant(
            of: find.byTooltip('自动跟随字幕'),
            matching: find.byType(InkWell),
          ),
        );
        toggle.onTap!();
        toggle.onTap!();
        await tester.pumpAndSettle();
        expect(SettingsService().autoScrollSubtitles, isFalse);
        expect(host.positions.any((item) => item.index == 0), isTrue);
        expect(find.byType(RawImage), findsNothing);
        await host.dispose();
      },
    );

    testWidgets(
      '$mode a newer locate wins over an earlier queued mode restore',
      (tester) async {
        final host = await _Host.create(tester, mode: mode);
        await tester.tap(find.text('1').first);
        await tester.pump();
        host.sidebar.locateToTime(host.cues[200].startTime, animated: false);
        await tester.pumpAndSettle();
        host.expectLocated(200);
        expect(tester.takeException(), isNull);
        await host.dispose();
      },
    );

    testWidgets('$mode reduced motion locates immediately', (tester) async {
      final host = await _Host.create(tester, mode: mode, reducedMotion: true);
      host.sidebar.locateToTime(host.cues[200].startTime);
      await _frames(tester, 3);
      host.expectLocated(200);
      expect(find.byType(RawImage), findsNothing);
      expect(host.scrollable.position.isScrollingNotifier.value, isFalse);
      await host.dispose();
    });
  }
}

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _Host {
  _Host(this.tester, this.mode, this.player, this.cues);

  final WidgetTester tester;
  final String mode;
  final VideoPlayerController player;
  final List<SubtitleItem> cues;
  final key = GlobalKey<SubtitleSidebarState>();
  final navigatorKey = GlobalKey<NavigatorState>();
  late StateSetter update;
  bool visible = true;
  double height = 420;
  int seeks = 0;
  bool? viewportReady;

  SubtitleSidebarState get sidebar => key.currentState!;
  double get readingOpacity => tester
      .widget<FadeTransition>(
        find.byKey(const ValueKey('transcript-location-opacity')),
      )
      .opacity
      .value;
  Finder get list => find.byType(ScrollablePositionedList).first;
  ScrollablePositionedList get listWidget =>
      tester.widget<ScrollablePositionedList>(list);
  Iterable<ItemPosition> get positions =>
      listWidget.itemPositionsNotifier!.itemPositions.value;
  ScrollableState get scrollable => tester.state<ScrollableState>(
    find.descendant(of: list, matching: find.byType(Scrollable)).first,
  );

  int itemForSubtitle(int subtitle) => mode == 'continuous'
      ? tester
            .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
            .layout
            .lineForSentence(subtitle)
      : subtitle;

  ItemPosition positionForSubtitle(int subtitle) =>
      positions.singleWhere((item) => item.index == itemForSubtitle(subtitle));

  Finder renderedItem(int subtitle) => find.descendant(
    of: list,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is IndexedSemantics &&
          widget.index == itemForSubtitle(subtitle),
      skipOffstage: false,
    ),
    skipOffstage: false,
  );

  double actualItemLeading(int subtitle) {
    final item = renderedItem(subtitle);
    return (tester.getTopLeft(item).dy - tester.getTopLeft(list).dy) /
        scrollable.position.viewportDimension;
  }

  bool isItemPainted(int subtitle) {
    final item = renderedItem(subtitle);
    if (item.evaluate().isEmpty) return false;
    RenderObject? ancestor = item.evaluate().single.findRenderObject();
    while (ancestor != null) {
      if (ancestor is RenderOpacity && ancestor.opacity == 0 ||
          ancestor is RenderAnimatedOpacity && ancestor.opacity.value == 0 ||
          ancestor is RenderOffstage && ancestor.offstage) {
        return false;
      }
      ancestor = ancestor.parent;
    }
    return tester.getRect(item).overlaps(tester.getRect(list));
  }

  Offset textPoint(int subtitle) {
    final viewport = tester.getRect(list);
    if (mode == 'continuous') {
      final view = tester.widget<ContinuousArticleView>(
        find.byType(ContinuousArticleView),
      );
      final sentence = view.document.sentenceForDisplayIndex(subtitle)!;
      for (final entry in view.layout.lines.indexed) {
        final line = entry.$2;
        if (!line.sentenceIndices.contains(subtitle)) continue;
        final text = find.byKey(
          ValueKey('subtitle-continuous-line-text-${entry.$1}'),
          skipOffstage: false,
        );
        if (text.evaluate().isEmpty) continue;
        final paragraph = tester.renderObject<RenderParagraph>(
          find
              .descendant(
                of: text,
                matching: find.byType(RichText, skipOffstage: false),
                skipOffstage: false,
              )
              .first,
        );
        final start = (sentence.start - line.paintStart).clamp(
          0,
          line.end - line.paintStart,
        );
        final end = (sentence.end - line.paintStart).clamp(
          start,
          line.end - line.paintStart,
        );
        if (start == end) continue;
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + 1),
        )) {
          final point = paragraph.localToGlobal(box.toRect().center);
          if (viewport.contains(point)) return point;
        }
      }
      throw StateError('Cue $subtitle has no visible text to tap.');
    }
    final cue = 'Sentence $subtitle,';
    for (final paragraph
        in tester.allRenderObjects.whereType<RenderParagraph>()) {
      if (!paragraph.hasSize) continue;
      final offset = paragraph.text.toPlainText().indexOf(cue);
      if (offset < 0) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      );
      for (final box in boxes) {
        final point = paragraph.localToGlobal(box.toRect().center);
        if (viewport.contains(point)) return point;
      }
    }
    throw StateError('Cue $subtitle has no visible text to tap.');
  }

  Map<int, Widget> readingBlocks() {
    final result = <int, Widget>{};
    if (mode == 'paragraph') {
      for (final chunk in tester.widgetList<SubtitleArticleChunk>(
        find.byType(SubtitleArticleChunk, skipOffstage: false),
      )) {
        final body = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byWidget(chunk, skipOffstage: false),
                matching: find.byType(Text, skipOffstage: false),
                skipOffstage: false,
              ),
            )
            .firstWhere((text) => text.textSpan != null);
        result[chunk.startIndex] = body;
      }
      return result;
    }
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: list,
        matching: find.byType(Text, skipOffstage: false),
        skipOffstage: false,
      ),
    )) {
      if (mode == 'continuous') {
        final key = text.key;
        if (key is ValueKey<String> &&
            key.value.startsWith('subtitle-continuous-line-text-')) {
          result[int.parse(key.value.split('-').last)] = text;
        }
      } else {
        final match = RegExp(r'^Sentence (\d+),').firstMatch(text.data ?? '');
        if (match != null) result[int.parse(match[1]!)] = text;
      }
    }
    return result;
  }

  int nearbySubtitle() {
    final item = positions.firstWhere(
      (item) => item.itemLeadingEdge >= .5 && item.itemLeadingEdge < .85,
    );
    return mode == 'continuous'
        ? tester
              .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
              .layout
              .lines[item.index]
              .sentenceIndices
              .first
        : item.index;
  }

  void expectLocated(int subtitle) {
    expect(positionForSubtitle(subtitle).itemLeadingEdge, closeTo(.3, .01));
  }

  void expectOpaqueSingleList() {
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(of: list, matching: find.byType(FadeTransition)),
    );
    expect(fades, hasLength(1));
    expect(fades.single.opacity.value, 1);
    expect(tester.takeException(), isNull);
  }

  Set<int> paintedSubtitles() {
    final viewport = tester.getRect(list);
    final result = <int>{};
    for (final paragraph
        in tester.allRenderObjects.whereType<RenderParagraph>()) {
      bool painted = true;
      RenderObject? ancestor = paragraph;
      while (ancestor != null) {
        if (ancestor is RenderOpacity && ancestor.opacity == 0 ||
            ancestor is RenderAnimatedOpacity && ancestor.opacity.value == 0 ||
            ancestor is RenderOffstage && ancestor.offstage) {
          painted = false;
          break;
        }
        ancestor = ancestor.parent;
      }
      if (!painted || !paragraph.hasSize) continue;
      final rect = MatrixUtils.transformRect(
        paragraph.getTransformTo(null),
        Offset.zero & paragraph.size,
      );
      if (!rect.overlaps(viewport)) continue;
      for (final match in RegExp(
        r'Sentence (\d+),',
      ).allMatches(paragraph.text.toPlainText())) {
        result.add(int.parse(match[1]!));
      }
    }
    return result;
  }

  static Future<_Host> create(
    WidgetTester tester, {
    required String mode,
    bool following = true,
    bool reducedMotion = false,
    bool preserveReading = false,
    TargetPlatform platform = TargetPlatform.android,
    bool skipInitialRepair = false,
    bool followSeeks = false,
    int locatePositionPercent = 30,
    int cueCount = 300,
    double width = 360,
  }) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': following,
      'subtitleViewMode': mode == 'list' ? 0 : 1,
      'subtitleArticleParagraphModeEnabled': mode != 'continuous',
      'subtitleArticleSentencesPerParagraph': 1,
      'landscapeSidebarLocatePositionPercent': locatePositionPercent,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final player = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/transcript-motion.mp4'),
    );
    player.value = VideoPlayerValue(
      duration: Duration(seconds: cueCount * 3 + 300),
      isInitialized: true,
      isPlaying: false,
    );
    final cues = List.generate(
      cueCount,
      (i) => SubtitleItem(
        index: i,
        startTime: Duration(seconds: i * 3),
        endTime: Duration(seconds: i * 3 + 3),
        text: 'Sentence $i, a readable subtitle. 字幕正文。',
      ),
    );
    final host = _Host(tester, mode, player, cues);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        navigatorKey: host.navigatorKey,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                host.update = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: host.height,
                    child: TickerMode(
                      enabled: host.visible,
                      child: Offstage(
                        offstage: !host.visible,
                        child: SubtitleSidebar(
                          key: host.key,
                          subtitles: cues,
                          controller: player,
                          isVisible: host.visible,
                          preserveReadingPositionWhenNotFollowing:
                              preserveReading,
                          onItemTap: (target) {
                            host.seeks++;
                            if (followSeeks) {
                              player.value = player.value.copyWith(
                                position: target,
                              );
                            }
                          },
                          onViewportReadyChanged: (ready) =>
                              host.viewportReady = ready,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!skipInitialRepair) {
      host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
      await tester.pumpAndSettle();
    }
    return host;
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  }
}
