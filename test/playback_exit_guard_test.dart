import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_exit_guard.dart';

void main() {
  test('accepts only the first playback exit request', () {
    final guard = PlaybackExitGuard();

    expect(guard.exitStarted, isFalse);
    expect(guard.tryStart(), isTrue);
    expect(guard.exitStarted, isTrue);
    expect(guard.tryStart(), isFalse);
    expect(guard.tryStart(), isFalse);
  });

  test('a second back press cannot pop after an asynchronous exit', () async {
    final guard = PlaybackExitGuard();
    final saveCompleted = Completer<void>();
    var popCount = 0;

    Future<void> exitPlayback() async {
      if (!guard.tryStart()) return;
      await saveCompleted.future;
      popCount++;
    }

    final firstBack = exitPlayback();
    final secondBack = exitPlayback();
    saveCompleted.complete();
    await Future.wait(<Future<void>>[firstBack, secondBack]);

    expect(popCount, 1);
  });
}
