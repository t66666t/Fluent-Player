import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  late bool previousConcurrent;
  late MediaPlaybackService playback;

  setUp(() {
    previousConcurrent = settings.allowConcurrentPlayback;
    settings.allowConcurrentPlayback = false;
    playback = MediaPlaybackService.forTesting();
  });

  tearDown(() {
    playback.dispose();
    settings.allowConcurrentPlayback = previousConcurrent;
  });

  for (final isIOS in [false, true]) {
    final platform = isIOS ? 'iOS' : 'Android';

    test('$platform late focus grant converges to the newer pause', () async {
      final firstGrant = Completer<bool>();
      final entered = Completer<void>();
      var nativeFocus = false;
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            entered.complete();
            await firstGrant.future;
          }
          nativeFocus = active;
          return true;
        },
      );

      final playing = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      final pausing = session.syncAudioFocusForTesting(desiredPlaying: false);
      await Future<void>.delayed(Duration.zero);
      firstGrant.complete(true);
      await Future.wait([playing, pausing]);

      expect(nativeFocus, isFalse);
      expect(calls.last, isFalse);
    });

    test('$platform late focus release converges to the newer play', () async {
      final release = Completer<void>();
      final entered = Completer<void>();
      var nativeFocus = false;
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (!active) {
            entered.complete();
            await release.future;
          }
          nativeFocus = active;
          return true;
        },
      );
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      final pausing = session.syncAudioFocusForTesting(desiredPlaying: false);
      await entered.future;
      final playing = session.syncAudioFocusForTesting(desiredPlaying: true);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait([pausing, playing]);

      expect(nativeFocus, isTrue);
      expect(calls.last, isTrue);
    });

    test('$platform rapid play pause play coalesces to the latest intent', () async {
      final grant = Completer<void>();
      final entered = Completer<void>();
      var nativeFocus = false;
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            entered.complete();
            await grant.future;
          }
          nativeFocus = active;
          return true;
        },
      );
      final first = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      final paused = session.syncAudioFocusForTesting(desiredPlaying: false);
      final last = session.syncAudioFocusForTesting(desiredPlaying: true);
      grant.complete();
      await Future.wait([first, paused, last]);

      expect(nativeFocus, isTrue);
      expect(calls, [true]);
    });

    test('$platform denied grant does not retry on unchanged progress', () async {
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          return !active;
        },
      );
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      for (var i = 0; i < 20; i++) {
        await session.syncAudioFocusForTesting(desiredPlaying: true);
      }
      expect(calls, [true, false]);

      // A real pause/play edge permits one new attempt even when the paused
      // publication is superseded before its queued native call runs.
      final paused = session.syncAudioFocusForTesting(desiredPlaying: false);
      final retry = session.syncAudioFocusForTesting(desiredPlaying: true);
      await Future.wait([paused, retry]);
      expect(calls, [true, false, true, false]);
    });

    test('$platform activation exception does not poison later intent', () async {
      final calls = <bool>[];
      var nativeFocus = false;
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            throw PlatformException(code: 'focus_test_denied');
          }
          nativeFocus = active;
          return true;
        },
      );
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      expect(calls, [true, false]);
      await session.syncAudioFocusForTesting(desiredPlaying: false);
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      expect(nativeFocus, isTrue);
      expect(calls, [true, false, true]);
    });

    test('$platform dispose compensates an in-flight grant', () async {
      final grant = Completer<void>();
      final entered = Completer<void>();
      var nativeFocus = false;
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            entered.complete();
            await grant.future;
          }
          nativeFocus = active;
          return true;
        },
      );
      final first = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      session.dispose();
      grant.complete();
      await first;
      await session.flushAudioFocusForTesting();
      expect(nativeFocus, isFalse);
      expect(calls, [true, false]);
    });

    test('$platform mix change during a grant releases exclusive focus', () async {
      final grant = Completer<void>();
      final entered = Completer<void>();
      var nativeFocus = false;
      final calls = <bool>[];
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: isIOS,
        setAudioSessionActive: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            entered.complete();
            await grant.future;
          }
          nativeFocus = active;
          return true;
        },
      );
      final first = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      settings.allowConcurrentPlayback = true;
      final mixed = session.syncAudioFocusForTesting(desiredPlaying: true);
      grant.complete();
      await Future.wait([first, mixed]);
      expect(nativeFocus, isFalse);
      expect(calls, [true, false]);
    });
  }

  test('Android denied request is cleared before a genuine later retry', () async {
    var storedRequest = false;
    var eligible = false;
    var nativeFocus = false;
    var systemRequests = 0;
    final session = SystemMediaSessionService.forTesting(
      playbackService: playback,
      setAudioSessionActive: (active) async {
        if (!active) {
          storedRequest = false;
          nativeFocus = false;
          return true;
        }
        // audio_session 0.2.4 AndroidAudioManager keeps the request object on
        // denial and returns true for a later call while that object exists.
        if (storedRequest) return true;
        storedRequest = true;
        systemRequests++;
        nativeFocus = eligible;
        return eligible;
      },
    );
    await session.syncAudioFocusForTesting(desiredPlaying: true);
    expect(nativeFocus, isFalse);
    expect(storedRequest, isFalse);
    eligible = true;
    final paused = session.syncAudioFocusForTesting(desiredPlaying: false);
    final resumed = session.syncAudioFocusForTesting(desiredPlaying: true);
    await Future.wait([paused, resumed]);
    expect(systemRequests, 2);
    expect(nativeFocus, isTrue);
  });

  test('failed denial cleanup cannot turn a cached request into a grant', () async {
    final calls = <bool>[];
    var storedRequest = false;
    var eligible = false;
    var nativeFocus = false;
    var failedCleanup = false;
    final session = SystemMediaSessionService.forTesting(
      playbackService: playback,
      setAudioSessionActive: (active) async {
        calls.add(active);
        if (!active) {
          if (!failedCleanup) {
            failedCleanup = true;
            throw PlatformException(code: 'focus_release_test_failure');
          }
          storedRequest = false;
          nativeFocus = false;
          return true;
        }
        if (storedRequest) return true;
        storedRequest = true;
        nativeFocus = eligible;
        return eligible;
      },
    );
    await session.syncAudioFocusForTesting(desiredPlaying: true);
    await session.syncAudioFocusForTesting(desiredPlaying: true);
    expect(calls, [true, false]);
    expect(nativeFocus, isFalse);
    eligible = true;
    final paused = session.syncAudioFocusForTesting(desiredPlaying: false);
    final resumed = session.syncAudioFocusForTesting(desiredPlaying: true);
    await Future.wait([paused, resumed]);
    expect(calls, [true, false, false, true]);
    expect(nativeFocus, isTrue);
  });

  for (final throwsInstead in [false, true]) {
    test('late ${throwsInstead ? 'exception' : 'denial'} cannot block a newer pause play edge', () async {
      final first = Completer<bool>();
      final entered = Completer<void>();
      var requests = 0;
      var nativeFocus = false;
      final session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        setAudioSessionActive: (active) async {
          if (active && ++requests == 1) {
            entered.complete();
            return first.future;
          }
          nativeFocus = active;
          return true;
        },
      );
      final old = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      final paused = session.syncAudioFocusForTesting(desiredPlaying: false);
      final resumed = session.syncAudioFocusForTesting(desiredPlaying: true);
      if (throwsInstead) {
        first.completeError(PlatformException(code: 'late_activation_failure'));
      } else {
        first.complete(false);
      }
      await Future.wait([old, paused, resumed]);
      expect(requests, 2);
      expect(nativeFocus, isTrue);
    });
  }

  test('same-intent progress pending a denial does not permit a retry storm', () async {
    final first = Completer<bool>();
    final entered = Completer<void>();
    var requests = 0;
    final session = SystemMediaSessionService.forTesting(
      playbackService: playback,
      setAudioSessionActive: (active) async {
        if (active) {
          requests++;
          if (requests == 1) {
            entered.complete();
            return first.future;
          }
          return false;
        }
        return true;
      },
    );
    final pending = [session.syncAudioFocusForTesting(desiredPlaying: true)];
    await entered.future;
    for (var i = 0; i < 20; i++) {
      pending.add(session.syncAudioFocusForTesting(desiredPlaying: true));
    }
    first.complete(false);
    await Future.wait(pending);
    expect(requests, 1);
  });
}
