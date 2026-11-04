import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/services/playback_startup.dart';
import 'package:video_player_app/widgets/bilibili_startup_poster.dart';

void main() {
  testWidgets('all online posters keep the 300ms hint and 120ms target fade', (
    tester,
  ) async {
    final startup = PlaybackStartupContext(elapsed: () => Duration.zero);
    Future<void> show(bool covered) => tester.pumpWidget(
      MaterialApp(
        home: BilibiliStartupPoster(startup: startup, covered: covered),
      ),
    );
    await show(true);
    await tester.pump(const Duration(milliseconds: 299));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    startup.prepared();
    await show(false);
    final fade = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('bilibili-startup-poster')),
    );
    expect(fade.opacity, 0);
    expect(fade.duration, const Duration(milliseconds: 120));
    expect(startup.isReady, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed cloud or podcast poster retains a retry action', (
    tester,
  ) async {
    final startup = PlaybackStartupContext();
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: BilibiliStartupPoster(
          startup: startup,
          covered: true,
          onRetry: () => retried = true,
        ),
      ),
    );
    startup.fail(TimeoutException('offline'));
    await tester.pump();
    expect(find.text('媒体加载超时，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'initial positioning, frame recovery and clock recovery are independent',
    () async {
      final startup = PlaybackStartupContext()..target = Duration.zero;
      expect(startup.claimPositionCorrection(), isTrue);
      final recovered = <Duration>[];
      for (final clock in [false, true]) {
        var rechecked = false;
        await startup.waitForFrame(
          Completer<void>().future,
          recheckFrame: () async => rechecked = true,
          recoverResume: (target) async => recovered.add(target),
          recoveryDelay: const Duration(milliseconds: 5),
          playbackClock: clock,
        );
        expect(rechecked, isTrue);
      }
      expect(recovered, [Duration.zero, Duration.zero]);
      expect(startup.claimPositionCorrection(), isFalse);
      expect(startup.claimFrameRecovery(), isFalse);
      expect(startup.claimClockRecovery(), isFalse);
    },
  );

  test(
    'a prepared output is still cancellable and uses the original deadline',
    () async {
      var elapsed = Duration.zero;
      final startup = PlaybackStartupContext(elapsed: () => elapsed);
      var aborted = false;
      startup.bindAbort(() => aborted = true);
      elapsed = const Duration(seconds: 29);
      startup.prepared();
      expect(startup.isPrepared, isTrue);
      expect(startup.isPending, isTrue);
      expect(startup.isReady, isFalse);
      expect(startup.remaining, const Duration(seconds: 1));
      final waiting = expectLater(
        startup.run(Completer<void>().future),
        throwsA(isA<PlaybackStartupCancelled>()),
      );
      startup.cancel();
      await waiting;
      expect(aborted, isTrue);
      startup.ready();
      expect(startup.isReady, isFalse);
    },
  );

  test(
    'retry shares elapsed budget and address refresh but has a new decoder',
    () async {
      var elapsed = const Duration(seconds: 27);
      final first = PlaybackStartupContext(elapsed: () => elapsed)
        ..target = const Duration(seconds: 23)
        ..desiredPlaying = false
        ..hasUserTarget = true;
      expect(first.claimAddressRefresh(), isTrue);
      expect(first.claimFrameRecovery(), isTrue);
      first.fail(StateError('network'));
      final retry = first.continueOnNewNetwork();
      expect(retry.remaining, const Duration(seconds: 3));
      expect(retry.target, first.target);
      expect(retry.hasUserTarget, isTrue);
      expect(retry.desiredPlaying, isFalse);
      expect(retry.claimAddressRefresh(), isFalse);
      expect(retry.claimFrameRecovery(), isTrue);
      elapsed = const Duration(seconds: 30);
      await expectLater(
        retry.run(Future.value()),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('an already running clock never sends a delayed recovery', () async {
    final startup = PlaybackStartupContext()
      ..target = const Duration(seconds: 23);
    var seeks = 0;
    await startup.waitForFrame(
      Future.value(),
      recheckFrame: () async => fail('No extra clock check is needed'),
      recoverResume: (_) async => seeks++,
      recoveryDelay: const Duration(milliseconds: 5),
      playbackClock: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seeks, 0);
    expect(startup.claimClockRecovery(), isTrue);
  });
}
