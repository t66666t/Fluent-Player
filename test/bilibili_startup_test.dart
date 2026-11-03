import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/bilibili/bilibili_startup.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/widgets/bilibili_startup_poster.dart';

void main() {
  test(
    'only this video sets its frame; covers and previous attempts cannot resize it',
    () {
      final previous = BilibiliStartupContext();
      previous.geometry.reportVideo(9 / 16);
      final next = BilibiliStartupContext();
      expect(next.geometry.aspectRatio, 16 / 9);
      next.geometry.reportCover(1);
      expect(next.geometry.coverAspectRatio, 1);
      expect(next.geometry.aspectRatio, 16 / 9);
      next.geometry.reportVideo(4 / 3);
      next.geometry.reportCover(9 / 16);
      next.geometry.reportVideo(double.nan);
      expect(next.geometry.aspectRatio, 4 / 3);
      final continuation = next.continueOnNewNetwork();
      expect(continuation.geometry.aspectRatio, 4 / 3);
      expect(continuation.geometry.coverAspectRatio, 9 / 16);
      expect(identical(next.geometry, continuation.geometry), isFalse);
    },
  );
  test('fast frames never schedule a corrective seek', () async {
    final startup = BilibiliStartupContext()
      ..target = const Duration(seconds: 23);
    var corrections = 0;
    await startup.waitForFrame(
      Future.value(),
      recheckFrame: () async => fail('A fast frame needs no second check'),
      recoverResume: (_) async => corrections++,
      recoveryDelay: const Duration(milliseconds: 20),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(corrections, 0);
    expect(startup.claimPositionCorrection(), isTrue);
  });

  test(
    'a recovered seek must finish and a fresh target frame must pass',
    () async {
      final startup = BilibiliStartupContext()
        ..target = const Duration(seconds: 23);
      final oldFrame = Completer<void>();
      final recoveryStarted = Completer<void>();
      final seekAck = Completer<void>();
      final newFrame = Completer<void>();
      var finished = false;
      var checks = 0;
      final waiting = startup
          .waitForFrame(
            oldFrame.future,
            recheckFrame: () {
              checks++;
              return newFrame.future;
            },
            recoverResume: (target) async {
              expect(target, const Duration(seconds: 23));
              recoveryStarted.complete();
              await seekAck.future;
            },
            recoveryDelay: const Duration(milliseconds: 20),
          )
          .then((_) => finished = true);
      await recoveryStarted.future;
      oldFrame.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(finished, isFalse);
      expect(checks, 0);
      seekAck.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(checks, 1);
      expect(finished, isFalse);
      newFrame.complete();
      await waiting;
      expect(startup.claimFrameRecovery(), isFalse);
      expect(startup.claimPositionCorrection(), isTrue);
    },
  );

  test(
    'user seeks and already-recovered startups do not receive another recovery',
    () async {
      for (final userSeek in [false, true]) {
        final startup =
            BilibiliStartupContext(limit: const Duration(milliseconds: 80))
              ..target = const Duration(seconds: 23)
              ..hasUserTarget = userSeek;
        if (!userSeek) expect(startup.claimFrameRecovery(), isTrue);
        var corrections = 0;
        await expectLater(
          startup.waitForFrame(
            Completer<void>().future,
            recheckFrame: () async {},
            recoverResume: (_) async => corrections++,
            recoveryDelay: const Duration(milliseconds: 20),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(corrections, 0);
      }
    },
  );

  test('cancelled frame waits cannot send a late recovery seek', () async {
    final startup = BilibiliStartupContext()
      ..target = const Duration(seconds: 23);
    var corrections = 0;
    final waiting = expectLater(
      startup.waitForFrame(
        Completer<void>().future,
        recheckFrame: () async {},
        recoverResume: (_) async => corrections++,
        recoveryDelay: const Duration(milliseconds: 20),
      ),
      throwsA(isA<BilibiliStartupCancelled>()),
    );
    startup.cancel();
    await waiting;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(corrections, 0);
  });

  test('deterministic playback denials retain a safe actionable reason', () {
    for (final message in ['地区限制', '需要大会员', '请先登录', '没有播放权限']) {
      final reason = BilibiliApiService.playbackRestriction({
        'code': -10403,
        'message': message,
      });
      expect(reason, isNotNull);
      final context = BilibiliStartupContext();
      var cancelled = false;
      context.bindAbort(() => cancelled = true);
      context.fail(StateError(reason!));
      expect(context.failure, reason);
      expect(cancelled, isTrue);
      expect(context.hasFailed, isTrue);
    }
    expect(
      BilibiliApiService.playbackRestriction({'code': 0, 'message': '地区可用'}),
      isNull,
    );
    expect(
      BilibiliApiService.playbackRestriction({
        'code': -500,
        'message': 'internal error',
      }),
      isNull,
    );
  });
  test(
    'all stages and network continuations consume the original deadline',
    () async {
      var elapsed = Duration.zero;
      final startup = BilibiliStartupContext(elapsed: () => elapsed);
      startup.target = const Duration(seconds: 42);
      startup.desiredPlaying = false;
      elapsed = const Duration(seconds: 19);
      startup.mark(BilibiliStartupPhase.connecting);
      expect(
        startup.bounded(const Duration(seconds: 20)),
        const Duration(seconds: 11),
      );
      final next = startup.continueOnNewNetwork();
      expect(next.target, startup.target);
      expect(next.desiredPlaying, isFalse);
      elapsed = const Duration(seconds: 30);
      await expectLater(
        next.run(Future.value()),
        throwsA(isA<TimeoutException>()),
      );
      startup.cancel();
    },
  );

  test(
    'cancellation stops every resource and observes late failures',
    () async {
      final startup = BilibiliStartupContext();
      var stopped = 0;
      startup.bindAbort(() {
        stopped++;
        throw StateError('already closed');
      });
      startup.bindAbort(() => stopped++);
      final work = Completer<void>();
      final result = expectLater(
        startup.run(work.future),
        throwsA(isA<BilibiliStartupCancelled>()),
      );
      startup.cancel();
      await result;
      work.completeError(StateError('late native error'));
      await Future<void>.delayed(Duration.zero);
      expect(stopped, 2);
      expect(startup.isCancelled, isTrue);
      startup.ready();
      expect(startup.isReady, isFalse);
    },
  );

  test(
    'successful playback and correction budgets are independent of elapsed time',
    () {
      var elapsed = Duration.zero;
      final startup = BilibiliStartupContext(elapsed: () => elapsed);
      expect(startup.claimAddressRefresh(), isTrue);
      expect(startup.claimAddressRefresh(), isFalse);
      expect(startup.claimPositionCorrection(), isTrue);
      expect(startup.claimPositionCorrection(), isFalse);
      startup.ready();
      elapsed = const Duration(hours: 4);
      expect(startup.check, returnsNormally);
      expect(
        startup.bounded(const Duration(seconds: 4)),
        const Duration(seconds: 4),
      );
    },
  );

  test(
    'an old texture and a seek acknowledgement cannot confirm a target frame',
    () {
      bool settled(Duration actual, {bool seeking = false}) =>
          NativeVideoPlayerMediaKit.positionHasSettled(
            actual: actual,
            target: const Duration(seconds: 42),
            seeking: seeking,
          );
      expect(settled(Duration.zero), isFalse);
      expect(settled(const Duration(seconds: 42), seeking: true), isFalse);
      expect(settled(const Duration(milliseconds: 42033)), isTrue);
    },
  );

  test('EDL escapes separators and uses UTF-8 byte lengths', () {
    const video = 'http://127.0.0.1:1234/video?name=中文;part=1';
    const audio = 'http://127.0.0.1:1234/audio';
    final edl = NativeVideoPlayerMediaKit.dualTrackEdl(video, audio);
    expect(edl, contains(';!new_stream;%${audio.length}%$audio'));
    expect(edl, startsWith('edl://%${video.length + 4}%$video'));
    expect(
      () => NativeVideoPlayerMediaKit.dualTrackEdl('file:///private', audio),
      throwsArgumentError,
    );
  });

  testWidgets('hint appears after 300ms; cover fades once on readiness', (
    tester,
  ) async {
    final startup = BilibiliStartupContext(elapsed: () => Duration.zero);
    Future<void> show(bool covered) => tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: BilibiliStartupPoster(startup: startup, covered: covered),
        ),
      ),
    );
    await show(true);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 299));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    startup.ready();
    await show(false);
    final fade = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('bilibili-startup-poster')),
    );
    expect(fade.opacity, 0);
    expect(fade.duration, const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a failed open keeps its poster and retry; leaving cancels the hint',
    (tester) async {
      final startup = BilibiliStartupContext();
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
      expect(find.text('视频加载超时，请重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );
}
