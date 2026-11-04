import 'dart:io';
import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'package:video_player_app/services/system_media_session_service.dart';

class _Playback extends MediaPlaybackService {
  _Playback() : super.forTesting();
  var item = VideoItem(
    id: 'ack-media',
    path: '/test-owned/ack.mp4',
    title: 'Actual publication',
    durationMs: 60000,
    lastUpdated: 1,
    hasProbedChapters: true,
  );
  var requestedPlaying = false;
  var hasItem = true;
  var sample = const Duration(seconds: 3);
  bool? publishedVisibility;

  @override
  VideoItem? get currentItem => hasItem ? item : null;
  @override
  PlaybackState get state => !hasItem
      ? PlaybackState.idle
      : requestedPlaying
      ? PlaybackState.playing
      : PlaybackState.paused;
  @override
  bool get isPlaying => requestedPlaying;
  @override
  bool get desiredPlaying => requestedPlaying;
  @override
  Duration get position => sample;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  void setMediaNotificationVisible(bool visible) {
    publishedVisibility = visible;
    super.setMediaNotificationVisible(visible);
  }
}

class NotificationAckAuditSession extends SystemMediaSessionService {
  NotificationAckAuditSession({
    required MediaPlaybackService playback,
    required PlaylistManager playlist,
  }) : super.forTesting(
         playbackService: playback,
         isIOS: true,
         setAudioSessionActive: (active) async => true,
       ) {
    handlerAudit = attachPublicationHandlerForTesting(
      playlistManager: playlist,
    );
  }

  @override
  bool get isSupportedPlatform => true;
  late final audio.BaseAudioHandler handlerAudit;
  bool get nativeSuppressedAudit =>
      notificationVisibilityForTesting.nativeSuppressed;
  bool get needsRearmAudit => notificationVisibilityForTesting.needsRearm;
  Future<void> publishAudit() => publishSnapshotForTesting();
  Future<void> refreshAudit() =>
      publishSnapshotForTesting(explicitRefresh: true);
  Future<void> drainAudit() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
      await flushPublicationsForTesting();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('com.ryanheise.audio_service.handler.methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final settings = SettingsService();
  late _Playback playback;
  late NotificationAckAuditSession session;
  late bool nativeVisible;
  late int showAttempts;
  late int hideAttempts;
  late bool rejectShow;
  late bool rejectHide;
  late String failureMode;
  late Directory files;
  Completer<void>? nextGate;
  bool? nextGateVisibility;
  Completer<bool>? delayedShow;
  Completer<void>? showStarted;

  Future<bool> androidGate(MethodCall call) async {
    final visible = call.method == 'armShow';
    if (visible) {
      showAttempts++;
    } else {
      hideAttempts++;
    }
    if (visible == nextGateVisibility &&
        nextGate != null &&
        !nextGate!.isCompleted) {
      nextGate!.complete();
    }
    if (visible && rejectShow) return false;
    nativeVisible = visible;
    return true;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    settings.showSystemMediaNotification = true;
    settings.enableHeadsetMediaControls = true;
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.iOS;
    nativeVisible = true;
    showAttempts = 0;
    hideAttempts = 0;
    rejectShow = false;
    rejectHide = false;
    failureMode = 'false acknowledgment';
    delayedShow = null;
    showStarted = null;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      expect(call.method, 'setNowPlayingVisible');
      final visible = (call.arguments as Map)['visible'] as bool;
      if (visible == nextGateVisibility &&
          nextGate != null &&
          !nextGate!.isCompleted) {
        nextGate!.complete();
      }
      if (visible) {
        showAttempts++;
        if (showStarted != null && !showStarted!.isCompleted) {
          showStarted!.complete();
        }
        if (delayedShow != null) {
          final applied = await delayedShow!.future;
          if (applied) nativeVisible = true;
          return applied;
        }
        if (rejectShow) {
          if (failureMode == 'platform error') {
            throw PlatformException(code: 'NOW_PLAYING_VISIBILITY');
          }
          if (failureMode == 'null acknowledgment') return null;
          return false;
        }
      } else {
        hideAttempts++;
        if (rejectHide) return false;
      }
      nativeVisible = visible;
      return true;
    });
    playback = _Playback();
    files = await Directory.systemTemp.createTemp('ios_notification_ack_');
    final cover = await File('${files.path}/cover.png').writeAsBytes([1]);
    playback.item.thumbnailPath = cover.path;
    session = NotificationAckAuditSession(
      playback: playback,
      playlist: PlaylistManager(),
    );
    await session.publishAudit();
    expect(playback.publishedVisibility, isTrue);
  });

  tearDown(() async {
    await session.drainAudit();
    session.dispose();
    await session.flushAudioFocusForTesting();
    playback.dispose();
    await files.delete(recursive: true);
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(
      SystemMediaNotificationGate.channel,
      null,
    );
    SystemMediaNotificationGate.debugTargetPlatform = null;
    settings.resetForTest();
  });

  Future<void> setting(bool value) async {
    nextGate = Completer<void>();
    nextGateVisibility = value;
    await settings.updateSetting('showSystemMediaNotification', value);
    // This is the actual settings listener/publication chain, not a gate call.
    await nextGate!.future.timeout(const Duration(seconds: 2));
    await session.drainAudit();
    nextGate = null;
    nextGateVisibility = null;
  }

  Future<void> hiddenThenRejectedShow() async {
    await setting(false);
    expect(hideAttempts, greaterThanOrEqualTo(1));
    expect(nativeVisible, isFalse);
    expect(session.nativeSuppressedAudit, isTrue);
    expect(playback.publishedVisibility, isFalse);
    rejectShow = true;
    await setting(true);
    expect(showAttempts, 1);
    expect(nativeVisible, isFalse);
  }

  for (final mode in [
    'false acknowledgment',
    'platform error',
    'null acknowledgment',
  ]) {
    test('a rejected native show cannot claim visibility: $mode', () async {
      failureMode = mode;
      await hiddenThenRejectedShow();
      expect(playback.publishedVisibility, isFalse);
      expect(session.nativeSuppressedAudit, isTrue);
      expect(session.needsRearmAudit, isTrue);
      expect(session.notificationVisibilityForTesting.visibleItemId, isNull);
      expect(session.notificationFailure.value?.requestedVisible, isTrue);
      expect(session.notificationFailure.value?.mediaId, playback.item.id);
    });
  }

  test(
    'position and headset intent publish without busy visibility retries',
    () async {
      await hiddenThenRejectedShow();
      for (var i = 0; i < 8; i++) {
        playback.sample += const Duration(milliseconds: 200);
        playback.requestedPlaying = i.isEven;
        await session.publishAudit();
        final state = session.handlerAudit.playbackState.value;
        expect(state.playing, playback.requestedPlaying);
        expect(session.notificationVisibilityForTesting.visibleItemId, isNull);
        expect(
          state.controls.map((c) => c.action),
          contains(
            playback.requestedPlaying
                ? audio.MediaAction.pause
                : audio.MediaAction.play,
          ),
        );
      }
      expect(
        showAttempts,
        1,
        reason: 'position/transport state is not a gate retry loop',
      );
      expect(nativeVisible, isFalse);
    },
  );

  test('a new explicit off-on intent retries a rejected show once', () async {
    await hiddenThenRejectedShow();
    rejectShow = false;
    await setting(false);
    await setting(true);
    expect(showAttempts, 2);
    expect(nativeVisible, isTrue);
    expect(playback.publishedVisibility, isTrue);
    expect(session.nativeSuppressedAudit, isFalse);
  });

  test(
    'an explicit refresh retries the failed visibility acknowledgment',
    () async {
      await hiddenThenRejectedShow();
      rejectShow = false;
      await session.refreshAudit();
      expect(showAttempts, 2);
      expect(nativeVisible, isTrue);
      expect(playback.publishedVisibility, isTrue);
      expect(session.notificationFailure.value, isNull);
    },
  );

  test(
    'a rejected explicit retry is latched until another explicit intent',
    () async {
      await hiddenThenRejectedShow();
      await session.refreshAudit();
      expect(showAttempts, 2);
      for (var i = 0; i < 8; i++) {
        playback.sample += const Duration(milliseconds: 200);
        await session.publishAudit();
      }
      expect(showAttempts, 2);
      expect(nativeVisible, isFalse);
      expect(playback.publishedVisibility, isFalse);
      rejectShow = false;
      await session.refreshAudit();
      expect(showAttempts, 3);
      expect(nativeVisible, isTrue);
    },
  );

  test('a late old show rejection cannot undo a newer hidden policy', () async {
    await setting(false);
    delayedShow = Completer<bool>();
    showStarted = Completer<void>();
    await settings.updateSetting('showSystemMediaNotification', true);
    await showStarted!.future.timeout(const Duration(seconds: 2));
    final hidingAgain = setting(false);
    delayedShow!.complete(false);
    await hidingAgain;
    expect(nativeVisible, isFalse);
    expect(playback.publishedVisibility, isFalse);
    expect(session.nativeSuppressedAudit, isTrue);
    expect(session.needsRearmAudit, isFalse);
    expect(showAttempts, 1);
    expect(session.notificationFailure.value, isNull);
  });

  test(
    'explicit UI retry exposes the current receipt without changing playback or settings',
    () async {
      await hiddenThenRejectedShow();
      final beforePlaying = playback.requestedPlaying;
      final beforePosition = playback.sample;
      rejectShow = false;
      await session.retryNotificationVisibility();
      await session.drainAudit();
      expect(showAttempts, 2);
      expect(session.notificationFailure.value, isNull);
      expect(nativeVisible, isTrue);
      expect(settings.showSystemMediaNotification, isTrue);
      expect(playback.requestedPlaying, beforePlaying);
      expect(playback.sample, beforePosition);
    },
  );

  test(
    'failed native conceal remains visible until an explicit retry succeeds',
    () async {
      rejectHide = true;
      await setting(false);
      expect(session.notificationFailure.value?.requestedVisible, isFalse);
      expect(nativeVisible, isTrue);
      final beforeAttempts = hideAttempts;
      rejectHide = false;
      await session.retryNotificationVisibility();
      await session.drainAudit();
      expect(hideAttempts, greaterThan(beforeAttempts));
      expect(session.notificationFailure.value, isNull);
      expect(nativeVisible, isFalse);
      expect(settings.showSystemMediaNotification, isFalse);
    },
  );

  test(
    'a new media item clears the previous media visibility failure',
    () async {
      await hiddenThenRejectedShow();
      playback.item = VideoItem(
        id: 'next-media',
        path: '/next.mp4',
        title: 'Next',
        durationMs: 60000,
        lastUpdated: 1,
        hasProbedChapters: true,
      );
      await session.publishAudit();
      expect(session.notificationFailure.value, isNull);
    },
  );

  test('unloading media clears a previously rejected native receipt', () async {
    await hiddenThenRejectedShow();
    playback.hasItem = false;
    await session.publishAudit();
    expect(session.notificationFailure.value, isNull);
  });

  test(
    'a native rejection without an owned media item is not a display failure',
    () async {
      playback.hasItem = false;
      rejectShow = true;
      await setting(false);
      await setting(true);
      expect(session.notificationFailure.value, isNull);
    },
  );

  test(
    'a late old media rejection cannot report failure for the next item',
    () async {
      await setting(false);
      delayedShow = Completer<bool>();
      showStarted = Completer<void>();
      await settings.updateSetting('showSystemMediaNotification', true);
      await showStarted!.future.timeout(const Duration(seconds: 2));
      playback.item = VideoItem(
        id: 'next-media',
        path: '/next.mp4',
        title: 'Next',
        durationMs: 60000,
        lastUpdated: 1,
        hasProbedChapters: true,
      );
      delayedShow!.complete(false);
      await session.drainAudit();
      expect(session.notificationFailure.value, isNull);
    },
  );

  test('Android paused priming cannot mark a rejected rearm visible', () async {
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      SystemMediaNotificationGate.channel,
      androidGate,
    );
    await hiddenThenRejectedShow();
    final states = <audio.PlaybackState>[];
    final subscription = session.handlerAudit.playbackState.listen(states.add);
    await session.publishSnapshotForTesting(ensureNotificationVisible: true);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(states.where((state) => state.playing), isEmpty);
    expect(session.notificationVisibilityForTesting.visibleItemId, isNull);
    expect(playback.publishedVisibility, isFalse);
    expect(showAttempts, 1);
  });

  test(
    'Android accepted rearm retains one paused priming transition',
    () async {
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        SystemMediaNotificationGate.channel,
        androidGate,
      );
      await hiddenThenRejectedShow();
      rejectShow = false;
      final states = <audio.PlaybackState>[];
      final subscription = session.handlerAudit.playbackState.listen(
        states.add,
      );
      await session.publishSnapshotForTesting(
        explicitRefresh: true,
        ensureNotificationVisible: true,
      );
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(states.where((state) => state.playing), hasLength(1));
      expect(states.last.playing, isFalse);
      expect(
        session.notificationVisibilityForTesting.visibleItemId,
        playback.item.id,
      );
      expect(playback.publishedVisibility, isTrue);
      expect(showAttempts, 2);
    },
  );

  test(
    'Android cold paused publication primes without a rearm request',
    () async {
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        SystemMediaNotificationGate.channel,
        androidGate,
      );
      final states = <audio.PlaybackState>[];
      final subscription = session.handlerAudit.playbackState.listen(
        states.add,
      );
      await session.publishSnapshotForTesting(ensureNotificationVisible: true);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(states.where((state) => state.playing), hasLength(1));
      expect(states.last.playing, isFalse);
      expect(
        session.notificationVisibilityForTesting.visibleItemId,
        playback.item.id,
      );
      expect(playback.publishedVisibility, isTrue);
      expect(showAttempts, 0);
    },
  );
  test('a late old successful show cannot undo a newer hidden epoch', () async {
    await setting(false);
    delayedShow = Completer<bool>();
    showStarted = Completer<void>();
    await settings.updateSetting('showSystemMediaNotification', true);
    await showStarted!.future.timeout(const Duration(seconds: 2));
    final hidingAgain = setting(false);
    delayedShow!.complete(true);
    await hidingAgain;
    expect(nativeVisible, isFalse);
    expect(playback.publishedVisibility, isFalse);
    expect(session.nativeSuppressedAudit, isTrue);
    expect(session.needsRearmAudit, isFalse);
    expect(showAttempts, 1);
  });

  test(
    'pending false with a new position does not retry the same intent',
    () async {
      await setting(false);
      final pending = delayedShow = Completer<bool>();
      showStarted = Completer<void>();
      await settings.updateSetting('showSystemMediaNotification', true);
      await showStarted!.future.timeout(const Duration(seconds: 2));
      expect(showAttempts, 1);
      playback.sample += const Duration(seconds: 2);
      final newerPosition = session.publishAudit();
      pending.complete(false);
      await newerPosition;
      await session.drainAudit();
      expect(showAttempts, 1);
      expect(nativeVisible, isFalse);
      expect(playback.publishedVisibility, isFalse);
      for (var i = 0; i < 8; i++) {
        playback.sample += const Duration(milliseconds: 200);
        await session.publishAudit();
      }
      expect(showAttempts, 1);
    },
  );

  test('pending false cannot consume a same-epoch explicit refresh', () async {
    await setting(false);
    final pending = delayedShow = Completer<bool>();
    showStarted = Completer<void>();
    await settings.updateSetting('showSystemMediaNotification', true);
    await showStarted!.future.timeout(const Duration(seconds: 2));
    final explicitRefresh = session.refreshAudit();
    // Only the old platform call is delayed. The new explicit attempt succeeds.
    delayedShow = null;
    pending.complete(false);
    await explicitRefresh;
    await session.drainAudit();
    expect(showAttempts, 2);
    expect(nativeVisible, isTrue);
    expect(playback.publishedVisibility, isTrue);
    playback.sample += const Duration(seconds: 2);
    await session.publishAudit();
    expect(showAttempts, 2);
  });

  test(
    'pending success with a newer position consumes the native receipt',
    () async {
      await setting(false);
      final pending = delayedShow = Completer<bool>();
      showStarted = Completer<void>();
      await settings.updateSetting('showSystemMediaNotification', true);
      await showStarted!.future.timeout(const Duration(seconds: 2));
      playback.sample += const Duration(seconds: 2);
      final newerPosition = session.publishAudit();
      pending.complete(true);
      await newerPosition;
      await session.drainAudit();
      expect(showAttempts, 1);
      expect(nativeVisible, isTrue);
      expect(playback.publishedVisibility, isTrue);
      expect(session.needsRearmAudit, isFalse);
    },
  );
}
