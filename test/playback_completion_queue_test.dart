import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Local player stand-in: every id gets its own event stream, nothing native
/// is created and nothing touches the network.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> positions = <int, Duration>{};
  int _nextPlayerId = 1;

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextPlayerId++;
    _events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void initializePlayer(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 1),
        size: const Size(1920, 1080),
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    positions.remove(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    if (positions.containsKey(playerId)) positions[playerId] = position;
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _Harness {
  _Harness._(this.platform, this.service, this.playlist, this.items);

  final _FakeVideoPlatform platform;
  final MediaPlaybackService service;
  final PlaylistManager playlist;
  final List<VideoItem> items;

  static Future<_Harness> create({
    required String prefix,
    required int itemCount,
    required bool autoPlayOnCompletion,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final sandbox = await Directory.systemTemp.createTemp(prefix);

    final settings = SettingsService();
    final originalAutoPlayNext = settings.autoPlayNextVideo;
    final originalAutoPlayOnCompletion = settings.autoPlayOnCompletion;
    final originalWrap = settings.playlistWrapToFirst;
    final originalFromStart = settings.autoPlayOnCompletionFromStart;
    settings.autoPlayNextVideo = false;
    settings.autoPlayOnCompletion = autoPlayOnCompletion;
    settings.playlistWrapToFirst = false;
    settings.autoPlayOnCompletionFromStart = true;

    final playlist = PlaylistManager(
      modeStore: PlaybackStateStore(platform: TargetPlatform.android),
    );
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    await service.sleepTimer.cancel();

    final items = <VideoItem>[
      for (var i = 0; i < itemCount; i++)
        VideoItem(
          id: '$prefix$i',
          path: '${sandbox.path}${Platform.pathSeparator}$i.mp4',
          title: 'Item $i',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
    ];
    for (final item in items) {
      await File(item.path).writeAsBytes(<int>[0]);
    }
    playlist.setPlaylist(items);

    addTearDown(() async {
      await service.sleepTimer.cancel();
      settings.autoPlayNextVideo = originalAutoPlayNext;
      settings.autoPlayOnCompletion = originalAutoPlayOnCompletion;
      settings.playlistWrapToFirst = originalWrap;
      settings.autoPlayOnCompletionFromStart = originalFromStart;
      await service.stop();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    return _Harness._(platform, service, playlist, items);
  }

  Future<void> startFirst() async {
    final play = service.play(items.first);
    await _until(() => platform.playerIds.contains(1));
    platform.initializePlayer(1);
    await play;
  }

  /// Plays a moment of the current item so the service accepts the next end sample
  /// as a real completion, then reports the end.
  void finishCurrent(int playerId) {
    final controller = service.controller!;
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 1),
      duration: const Duration(minutes: 1),
      isPlaying: true,
    );
    service.updatePlaybackStateFromController(
      expectedItemId: service.currentItem!.id,
      expectedController: controller,
    );
    platform.positions[playerId] = const Duration(minutes: 1);
    controller.value = controller.value.copyWith(
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 1),
      isPlaying: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('custom queue order drives EOF continuation without restarting the current item', () async {
    final h = await _Harness.create(prefix: 'sort_queue_', itemCount: 3, autoPlayOnCompletion: true);
    await h.startFirst();
    final currentController = h.service.controller;
    h.playlist.reorderQueue([h.items[0].id, h.items[2].id, h.items[1].id]);
    expect(h.service.controller, same(currentController));
    expect(h.service.nextPlayableItem?.id, h.items[2].id);
    h.finishCurrent(1);
    await _until(() => h.platform.playerIds.contains(2));
    h.platform.initializePlayer(2);
    await _until(() => h.service.currentItem?.id == h.items[2].id && h.service.state == PlaybackState.playing);
    expect(h.service.currentItem?.id, h.items[2].id);
    expect(h.service.nextPlayableItem?.id, h.items[1].id);
  });

  test('removing queued and current items keeps the running controller', () async {
    final h = await _Harness.create(
      prefix: 'remove_current_', itemCount: 3, autoPlayOnCompletion: true,
    );
    await h.startFirst();
    final controller = h.service.controller;
    final state = h.service.state;
    h.playlist.removeFromQueue(h.items[1].id);
    expect(h.service.nextPlayableItem?.id, h.items[2].id);
    h.playlist.removeFromQueue(h.items.first.id);
    expect(h.service.controller, same(controller));
    expect(h.service.currentItem?.id, h.items.first.id);
    expect(h.service.state, state);
    expect(h.playlist.isCurrentItemDetached, isTrue);
    expect(h.platform.playerIds, contains(1));
    expect(File(h.items.first.path).existsSync(), isTrue);
  });

  test('a pause during EOF confirmation cancels automatic repeat', () async {
    final h = await _Harness.create(
      prefix: 'mode_pause_end_',
      itemCount: 2,
      autoPlayOnCompletion: true,
    );
    await h.startFirst();
    h.playlist.setPlaybackMode(PlaybackMode.repeatOne);
    h.finishCurrent(1);
    await h.service.pause();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(h.service.state, PlaybackState.paused);
    expect(h.service.controller!.value.isPlaying, isFalse);
    expect(h.service.currentItem?.id, h.items.first.id);
  });

  test('count-based sleep timer also counts repeat-one completions', () async {
    final h = await _Harness.create(
      prefix: 'mode_repeat_count_',
      itemCount: 2,
      autoPlayOnCompletion: false,
    );
    await h.startFirst();
    h.playlist.setPlaybackMode(PlaybackMode.repeatOne);
    await h.service.sleepTimer.scheduleAfterItems(1);
    h.finishCurrent(1);
    await _until(
      () =>
          h.service.state == PlaybackState.playing &&
          h.service.controller!.value.isPlaying &&
          h.service.position == Duration.zero,
    );
    expect(h.service.sleepTimer.remainingItemCount, 1);
    h.finishCurrent(1);
    await _until(() => h.service.state == PlaybackState.paused);
    expect(h.service.currentItem?.id, h.items.first.id);
    expect(h.service.sleepTimer.isActive, isFalse);
    expect(h.platform.playerIds, [1]);
  });

  test(
    'repeat-one restarts the current controller with automatic continuation off',
    () async {
      final h = await _Harness.create(
        prefix: 'mode_repeat_',
        itemCount: 3,
        autoPlayOnCompletion: false,
      );
      await h.startFirst();
      final controller = h.service.controller!;
      h.playlist.setPlaybackMode(PlaybackMode.repeatOne);
      h.finishCurrent(1);
      await _until(
        () =>
            h.service.position == Duration.zero &&
            h.service.state == PlaybackState.playing &&
            controller.value.isPlaying,
      );
      expect(h.service.currentItem?.id, h.items.first.id);
      expect(h.service.controller, same(controller));
      expect(h.service.position, Duration.zero);
      expect(controller.value.isPlaying, isTrue);
      expect(controller.value.isLooping, isFalse);
      expect(h.service.nextPlayableItem?.id, h.items[1].id);
      expect(h.platform.playerIds, [1]);
    },
  );

  test('end-of-item sleep timer wins over repeat-one', () async {
    final h = await _Harness.create(
      prefix: 'mode_repeat_stop_',
      itemCount: 2,
      autoPlayOnCompletion: true,
    );
    await h.startFirst();
    h.playlist.setPlaybackMode(PlaybackMode.repeatOne);
    await h.service.sleepTimer.scheduleAtEndOfCurrentItem();
    h.finishCurrent(1);
    await _until(() => h.service.state == PlaybackState.paused);
    expect(h.service.currentItem?.id, h.items.first.id);
    expect(h.service.state, PlaybackState.paused);
    expect(h.service.sleepTimer.isActive, isFalse);
    expect(h.platform.playerIds, [1]);
  });

  test('random EOF and manual next share the advertised next item', () async {
    final h = await _Harness.create(
      prefix: 'mode_random_',
      itemCount: 5,
      autoPlayOnCompletion: true,
    );
    await h.startFirst();
    final controller = h.service.controller;
    h.playlist.setPlaybackMode(PlaybackMode.shuffle);
    expect(h.service.controller, same(controller));
    final target = h.service.nextPlayableItem!;
    expect(
      h.playlist.playbackQueue[h.playlist.playbackIndex + 1].id,
      target.id,
    );
    h.finishCurrent(1);
    await _until(() => h.platform.playerIds.contains(2));
    h.platform.initializePlayer(2);
    await _until(
      () =>
          h.service.state == PlaybackState.playing &&
          h.service.currentItem?.id == target.id,
    );
    expect(h.service.currentItem?.id, target.id);
    expect(h.service.previousPlayableItem?.id, h.items.first.id);
    final next = h.service.nextPlayableItem!;
    final skip = h.service.playNext();
    await _until(() => h.platform.playerIds.contains(3));
    h.platform.initializePlayer(3);
    await skip;
    expect(h.service.currentItem?.id, next.id);
    expect(
      h.service.state,
      PlaybackState.paused,
      reason: 'manual skip respects the existing switch-autoplay preference',
    );
    expect(h.service.previousPlayableItem?.id, target.id);
  });

  test(
    'random mode with continuation disabled stays on the finished item',
    () async {
      final h = await _Harness.create(
        prefix: 'mode_random_stop_',
        itemCount: 4,
        autoPlayOnCompletion: false,
      );
      await h.startFirst();
      h.playlist.setPlaybackMode(PlaybackMode.shuffle);
      final next = h.service.nextPlayableItem!.id;
      h.finishCurrent(1);
      await _until(() => h.service.state == PlaybackState.paused);
      expect(h.service.currentItem?.id, h.items.first.id);
      expect(h.service.nextPlayableItem?.id, next);
      expect(h.platform.playerIds, [1]);
    },
  );

  test('a finished item stays paused at EOF with a restart-at-zero bookmark '
      'despite trailing native samples', () async {
    final h = await _Harness.create(
      prefix: 'completion_park_',
      itemCount: 2,
      autoPlayOnCompletion: false,
    );
    await h.startFirst();
    final controller = h.service.controller!;
    h.finishCurrent(1);
    await _until(() => h.service.state == PlaybackState.paused);

    expect(h.service.currentItem?.id, h.items.first.id);
    expect(h.service.state, PlaybackState.paused);
    expect(h.service.position, const Duration(minutes: 1));
    expect(h.service.positionNotifier.value, h.service.duration);
    expect(h.service.coarsePositionNotifier.value, h.service.duration);
    expect(
      h.service.positionForProgressChrome(Duration.zero),
      h.service.duration,
    );
    expect(controller.value.position, h.service.duration);
    expect(controller.value.isPlaying, isFalse);
    expect(h.service.controller, same(controller));
    expect(h.platform.positions[1], h.service.duration);
    expect(h.platform.playerIds, <int>[1], reason: 'no next item opened');
    final snapshot = await ProgressTracker().restorePlaybackState();
    expect(snapshot?.currentItemId, h.items.first.id);
    expect(snapshot?.positionMs, 0);

    // EOF callbacks may trail the final frame or briefly report byte zero.
    for (final sample in [
      const Duration(milliseconds: 59920),
      Duration.zero,
      const Duration(minutes: 1),
    ]) {
      controller.value = controller.value.copyWith(
        position: sample,
        isPlaying: false,
      );
      h.service.updatePlaybackStateFromController(
        expectedItemId: h.items.first.id,
        expectedController: controller,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.service.position, h.service.duration);
      expect(h.service.positionNotifier.value, h.service.duration);
      expect(h.service.coarsePositionNotifier.value, h.service.duration);
      expect(h.service.state, PlaybackState.paused);
    }
    await h.service.persistCurrentProgress();
    expect((await ProgressTracker().restorePlaybackState())?.positionMs, 0);
  });

  for (final seekPosition in [null, const Duration(seconds: 20)]) {
    test(
      'resuming a finished item starts at ${seekPosition ?? Duration.zero}',
      () async {
        final h = await _Harness.create(
          prefix: 'completion_resume_',
          itemCount: 2,
          autoPlayOnCompletion: false,
        );
        await h.startFirst();
        final controller = h.service.controller!;
        h.finishCurrent(1);
        await _until(() => h.service.state == PlaybackState.paused);
        expect(h.service.position, h.service.duration);

        if (seekPosition != null) {
          await h.service.seekTo(seekPosition);
          expect(h.service.state, PlaybackState.paused);
          expect(h.service.position, seekPosition);
        }
        await h.service.resume();
        expect(h.service.position, seekPosition ?? Duration.zero);
        expect(
          (h.service.positionNotifier.value - (seekPosition ?? Duration.zero))
              .inMilliseconds
              .abs(),
          lessThan(100),
          reason: 'the resumed clock may already have advanced',
        );
        expect(h.service.controller, same(controller));
        expect(h.service.currentItem?.id, h.items.first.id);
        expect(h.service.state, PlaybackState.playing);
        expect(controller.value.isPlaying, isTrue);
        expect(h.platform.playerIds, [1]);
      },
    );
  }

  test('"play N more" keeps advancing with auto-play off and stops when '
      'the count is used up', () async {
    final h = await _Harness.create(
      prefix: 'timer_count_',
      itemCount: 3,
      autoPlayOnCompletion: false,
    );
    await h.startFirst();
    await h.service.sleepTimer.scheduleAfterItems(1);

    // The current item ends: that is not counted, the next one opens.
    h.finishCurrent(1);
    await _until(() => h.platform.playerIds.contains(2));
    expect(
      h.platform.playerIds,
      contains(2),
      reason: 'the timer asks for one more item even with auto-play off',
    );
    h.platform.initializePlayer(2);
    await _until(() => h.service.currentItem?.id == h.items[1].id);
    expect(h.service.currentItem?.id, h.items[1].id);
    expect(h.service.sleepTimer.isActive, isTrue);
    expect(h.service.sleepTimer.remainingItemCount, 1);

    // The one extra item ends: the count is used up, playback stops here.
    await _until(() => h.service.state == PlaybackState.playing);
    h.finishCurrent(2);
    await _until(() => !h.service.sleepTimer.isActive);
    await _until(() => h.service.state == PlaybackState.paused);
    expect(h.service.sleepTimer.isActive, isFalse);
    expect(h.service.currentItem?.id, h.items[1].id);
    expect(h.service.state, PlaybackState.paused);
    expect(h.service.position, const Duration(minutes: 1));
    expect(h.platform.playerIds, isNot(contains(3)));
  });

  test('a count-based timer that outlasts the queue parks on the last item '
      'instead of closing the player', () async {
    final h = await _Harness.create(
      prefix: 'timer_queue_end_',
      itemCount: 2,
      autoPlayOnCompletion: false,
    );
    await h.startFirst();
    await h.service.sleepTimer.scheduleAfterItems(5);

    h.finishCurrent(1);
    await _until(() => h.platform.playerIds.contains(2));
    h.platform.initializePlayer(2);
    await _until(
      () =>
          h.service.currentItem?.id == h.items[1].id &&
          h.service.state == PlaybackState.playing,
    );
    final lastController = h.service.controller;
    h.finishCurrent(2);
    await _until(() => !h.service.sleepTimer.isActive);
    await _until(() => h.service.state == PlaybackState.paused);

    expect(h.service.sleepTimer.isActive, isFalse);
    expect(h.service.currentItem?.id, h.items[1].id);
    expect(h.service.state, PlaybackState.paused);
    expect(h.service.controller, same(lastController));
    expect(h.platform.playerIds, contains(2), reason: 'player not disposed');
  });

  testWidgets('with list wrap on, the episode list can go back from the '
      'first item', (tester) async {
    late _Harness h;
    await tester.runAsync(() async {
      h = await _Harness.create(
        prefix: 'wrap_panel_',
        itemCount: 3,
        autoPlayOnCompletion: false,
      );
    });
    final settings = SettingsService();
    final previousValueTypeCheck = Provider.debugCheckInvalidValueType;
    Provider.debugCheckInvalidValueType = null;
    addTearDown(
      () => Provider.debugCheckInvalidValueType = previousValueTypeCheck,
    );

    IconButton previousButton() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous),
    );

    Future<void> showPanel() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaylistManager>.value(value: h.playlist),
            Provider<MediaPlaybackService>.value(value: h.service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: EpisodePickerPanel(
                panelWidth: 480,
                panelHeight: 600,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    settings.playlistWrapToFirst = true;
    h.playlist.setPlaylist(h.items, startIndex: 0);
    await showPanel();
    expect(previousButton().onPressed, isNotNull);

    settings.playlistWrapToFirst = false;
    await tester.pumpWidget(const SizedBox());
    await showPanel();
    expect(previousButton().onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('the playback pages enable 上一集 from the service, which knows about '
      'list wrap', () {
    for (final path in <String>[
      'lib/screens/video_player_screen.dart',
      'lib/screens/portrait_video_screen.dart',
      'lib/widgets/episode_picker_panel.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('.hasPlayablePrevious'), reason: path);
      expect(
        source,
        isNot(contains('playlistManager.hasPrevious')),
        reason: path,
      );
      expect(
        RegExp(
          r'PlaylistManager\s*>\s*\(\s*context\s*\)\s*\.hasPrevious',
        ).hasMatch(source),
        isFalse,
        reason: path,
      );
    }
  });
}
