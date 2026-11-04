import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:video_player_app/services/sleep_timer_controller.dart';

class _FakePlayback extends ChangeNotifier {
  bool playing = false;

  void setPlaying(bool value) {
    playing = value;
    notifyListeners();
  }
}

class _BlockedTimerPreferences extends InMemorySharedPreferencesStore {
  _BlockedTimerPreferences() : super.withData(<String, Object>{});
  Completer<void>? blocked;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await blocked?.future;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'expiration pauses before a blocked preference write finishes',
    () async {
      final originalStore = SharedPreferencesStorePlatform.instance;
      final store = _BlockedTimerPreferences();
      SharedPreferencesStorePlatform.instance = store;
      var now = DateTime(2026, 10, 30, 23);
      final playback = _FakePlayback()..playing = true;
      final timer = SleepTimerController(now: () => now);
      try {
        await timer.initialize(
          playbackListenable: playback,
          isPlaybackRunning: () => playback.playing,
          onExpired: () async => playback.setPlaying(false),
        );
        await timer.scheduleAfter(const Duration(minutes: 1));
        store.blocked = Completer<void>();
        now = now.add(const Duration(minutes: 1));
        timer.checkNow();
        await Future<void>.delayed(Duration.zero);
        expect(
          playback.playing,
          isFalse,
          reason: 'Stopping audio must not wait for disk/preferences.',
        );
        expect(timer.isActive, isFalse);
      } finally {
        store.blocked?.complete();
        await timer.flushPreferencesForTrial();
        timer.dispose();
        playback.dispose();
        SharedPreferencesStorePlatform.instance = originalStore;
      }
    },
  );

  test('a new timer can expire while the previous expiry is saving', () async {
    final originalStore = SharedPreferencesStorePlatform.instance;
    final store = _BlockedTimerPreferences();
    SharedPreferencesStorePlatform.instance = store;
    var now = DateTime(2026, 10, 30, 23);
    final playback = _FakePlayback()..playing = true;
    final timer = SleepTimerController(now: () => now);
    var expirations = 0;
    Future<void>? scheduling;
    try {
      await timer.initialize(
        playbackListenable: playback,
        isPlaybackRunning: () => playback.playing,
        onExpired: () async {
          expirations++;
          playback.setPlaying(false);
        },
      );
      await timer.scheduleAfter(const Duration(minutes: 1));
      store.blocked = Completer<void>();
      now = now.add(const Duration(minutes: 1));
      timer.checkNow();
      expect(expirations, 1);

      playback.setPlaying(true);
      scheduling = timer.scheduleAfter(const Duration(minutes: 1));
      now = now.add(const Duration(minutes: 1));
      timer.checkNow();
      expect(expirations, 2);
      expect(playback.playing, isFalse);
      timer.checkNow();
      expect(expirations, 2);
    } finally {
      store.blocked?.complete();
      await scheduling;
      await timer.flushPreferencesForTrial();
      timer.dispose();
      playback.dispose();
      SharedPreferencesStorePlatform.instance = originalStore;
    }
  });

  test('wall-clock countdown continues while playback is paused', () async {
    var now = DateTime(2026, 9, 7, 22);
    var expirationCount = 0;
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => now);
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async => expirationCount++,
    );

    await timer.scheduleAfter(const Duration(minutes: 30));
    now = now.add(const Duration(minutes: 29));
    timer.checkNow();
    expect(timer.isActive, isTrue);

    now = now.add(const Duration(minutes: 1));
    timer.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(timer.isActive, isFalse);
    expect(expirationCount, 1);
    timer.dispose();
  });

  test('effective-playback countdown stops while paused', () async {
    var now = DateTime(2026, 9, 7, 22);
    var expirationCount = 0;
    final playback = _FakePlayback()..playing = true;
    final timer = SleepTimerController(now: () => now);
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async => expirationCount++,
    );

    await timer.scheduleAfter(
      const Duration(minutes: 30),
      countOnlyWhilePlaying: true,
    );
    now = now.add(const Duration(minutes: 10));
    playback.setPlaying(false);
    now = now.add(const Duration(hours: 2));
    timer.checkNow();
    expect(timer.remaining, const Duration(minutes: 20));
    expect(expirationCount, 0);

    playback.setPlaying(true);
    now = now.add(const Duration(minutes: 20));
    timer.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(timer.isActive, isFalse);
    expect(expirationCount, 1);
    timer.dispose();
  });

  test('item and queue completion rules prevent unwanted auto-play', () async {
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => DateTime(2026, 9, 7));
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );

    await timer.scheduleAtEndOfCurrentItem();
    expect(timer.consumeItemCompletion(hasNextItem: true), isTrue);
    expect(timer.isActive, isFalse);

    await timer.scheduleAtEndOfQueue();
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.consumeItemCompletion(hasNextItem: false), isTrue);

    await timer.scheduleAfterItems(1);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.remainingItemCount, 1);
    expect(timer.awaitingCurrentItemEnd, isFalse);
    expect(timer.consumeItemCompletion(hasNextItem: true), isTrue);

    await timer.scheduleAfterItems(3);
    expect(timer.scheduledItemCount, 3);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.remainingItemCount, 3);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.remainingItemCount, 2);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.remainingItemCount, 1);
    expect(timer.scheduledItemCount, 3);
    expect(timer.consumeItemCompletion(hasNextItem: true), isTrue);
    timer.dispose();
  });

  test('absolute countdown survives restart without being extended', () async {
    var now = DateTime(2026, 9, 7, 22);
    final playback = _FakePlayback();
    final first = SleepTimerController(now: () => now);
    await first.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    await first.scheduleAfter(const Duration(minutes: 45));
    first.dispose();

    now = now.add(const Duration(minutes: 15));
    final restored = SleepTimerController(now: () => now);
    await restored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    expect(restored.mode, SleepTimerMode.afterDuration);
    expect(restored.remaining, const Duration(minutes: 30));
    restored.dispose();
  });

  test('latest command wins when persistence operations overlap', () async {
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => DateTime(2026, 9, 7, 22));
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );

    final schedule = timer.scheduleAfter(const Duration(minutes: 30));
    final cancel = timer.cancel();
    await Future.wait([schedule, cancel]);
    final preferences = await SharedPreferences.getInstance();
    expect(timer.isActive, isFalse);
    expect(preferences.containsKey('sleepTimer.mode'), isFalse);
    expect(preferences.containsKey('sleepTimer.deadlineMs'), isFalse);
    timer.dispose();
  });

  test('counting preference and custom minutes survive a restart', () async {
    final playback = _FakePlayback();
    final first = SleepTimerController(now: () => DateTime(2026, 9, 7, 22));
    await first.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    await first.setCountOnlyWhilePlaying(true);
    await first.setCustomMinutes(75);
    await first.setCustomItemCount(12);
    await first.cancel();
    first.dispose();

    final restored = SleepTimerController(now: () => DateTime(2026, 9, 7, 22));
    await restored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    expect(restored.countOnlyWhilePlaying, isTrue);
    expect(restored.customMinutes, 75);
    expect(restored.customItemCount, 12);
    expect(restored.isActive, isFalse);
    restored.dispose();
  });

  test('running duration timer converts without changing time left', () async {
    var now = DateTime(2026, 9, 7, 22);
    final playback = _FakePlayback()..playing = true;
    final timer = SleepTimerController(now: () => now);
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    await timer.scheduleAfter(const Duration(minutes: 30));
    now = now.add(const Duration(minutes: 5));
    await timer.setCountOnlyWhilePlaying(true);
    expect(timer.mode, SleepTimerMode.afterPlaybackDuration);
    expect(timer.remaining, const Duration(minutes: 25));

    playback.setPlaying(false);
    now = now.add(const Duration(hours: 1));
    timer.checkNow();
    expect(timer.remaining, const Duration(minutes: 25));

    await timer.setCountOnlyWhilePlaying(false);
    expect(timer.mode, SleepTimerMode.afterDuration);
    expect(timer.remaining, const Duration(minutes: 25));
    timer.dispose();
  });

  test('playback, completion, and item-count timers survive restart', () async {
    var now = DateTime(2026, 9, 7, 22);
    final playback = _FakePlayback()..playing = true;
    final first = SleepTimerController(now: () => now);
    await first.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );

    await first.scheduleAfter(
      const Duration(minutes: 40),
      countOnlyWhilePlaying: true,
    );
    now = now.add(const Duration(minutes: 10));
    first.checkNow();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    first.dispose();

    final playbackRestored = SleepTimerController(now: () => now);
    await playbackRestored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => false,
      onExpired: () async {},
    );
    expect(playbackRestored.mode, SleepTimerMode.afterPlaybackDuration);
    expect(playbackRestored.remaining, const Duration(minutes: 30));
    playbackRestored.dispose();

    final completion = SleepTimerController(now: () => now);
    await completion.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => false,
      onExpired: () async {},
    );
    await completion.scheduleAtEndOfCurrentItem();
    completion.dispose();
    final completionRestored = SleepTimerController(now: () => now);
    await completionRestored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => false,
      onExpired: () async {},
    );
    expect(completionRestored.mode, SleepTimerMode.endOfCurrentItem);
    completionRestored.dispose();

    final items = SleepTimerController(now: () => now);
    await items.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => false,
      onExpired: () async {},
    );
    await items.scheduleAfterItems(3);
    expect(items.consumeItemCompletion(hasNextItem: true), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    items.dispose();
    final itemsRestored = SleepTimerController(now: () => now);
    await itemsRestored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => false,
      onExpired: () async {},
    );
    expect(itemsRestored.mode, SleepTimerMode.afterItemCount);
    expect(itemsRestored.remainingItemCount, 3);
    expect(itemsRestored.scheduledItemCount, 3);
    expect(itemsRestored.awaitingCurrentItemEnd, isFalse);
    itemsRestored.dispose();
  });

  test(
    'paused or stalled playback does not reduce playback countdown',
    () async {
      var now = DateTime(2026, 9, 7, 22);
      final playback = _FakePlayback()..playing = true;
      final timer = SleepTimerController(now: () => now);
      await timer.initialize(
        playbackListenable: playback,
        isPlaybackRunning: () => playback.playing,
        onExpired: () async {},
      );
      await timer.scheduleAfter(
        const Duration(minutes: 20),
        countOnlyWhilePlaying: true,
      );
      now = now.add(const Duration(minutes: 4));
      playback.setPlaying(false);
      now = now.add(const Duration(minutes: 9));
      timer.checkNow();
      expect(timer.remaining, const Duration(minutes: 16));
      timer.dispose();
    },
  );
}
