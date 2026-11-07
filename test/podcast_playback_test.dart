import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_policy.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';
import 'podcast_core_test.dart' show podcastFixture;

class _PodcastPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{},
      positions = <int, Duration>{};
  final sources = <DataSource>[], speeds = <double>[];
  var next = 1;
  bool advanceOnPlay = true;
  final playing = <int>{};
  Completer<void>? seekGate;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = next++;
    sources.add(options.dataSource);
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(
      () => events[playerId]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: Size.zero,
        ),
      ),
    );
    return events[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await events.remove(playerId)?.close();
    positions.remove(playerId);
    _clocks.remove(playerId);
  }

  @override
  Future<void> play(int playerId) async {
    _clocks.putIfAbsent(playerId, Stopwatch.new).start();
    playing.add(playerId);
    events[playerId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ),
    );
  }

  @override
  Future<void> pause(int playerId) async {
    positions[playerId] = await getPosition(playerId);
    _clocks[playerId]
      ?..stop()
      ..reset();
    playing.remove(playerId);
    events[playerId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: false,
      ),
    );
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    await seekGate?.future;
    positions[playerId] = position;
    _clocks[playerId]?.reset();
  }

  final _clocks = <int, Stopwatch>{};

  @override
  Future<Duration> getPosition(int playerId) async =>
      (positions[playerId] ?? Duration.zero) +
      (advanceOnPlay && playing.contains(playerId)
          ? _clocks[playerId]?.elapsed ?? Duration.zero
          : Duration.zero);
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    speeds.add(speed);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
  @override
  Widget buildView(int playerId) => const SizedBox();
}

class _MemoryPlaybackStateStore extends PlaybackStateStore {
  Map<String, dynamic>? snapshot;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    snapshot = Map.of(value);
  }

  @override
  Future<Map<String, dynamic>?> read() async => snapshot;
}

Future<void> _pumpPlayback(WidgetTester tester, Future<void> action) async {
  var done = false;
  Object? failure;
  action.then<void>(
    (_) { done = true; },
    onError: (Object error, StackTrace _) {
      failure = error;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(
    done,
    isTrue,
    reason: 'Playback must settle while the fake clock runs',
  );
  if (failure != null) throw failure!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The singleton's command futures must belong to the real test zone rather
  // than a widget test's discarded fake clock.
  MediaPlaybackService();
  for (final pausedBeforeCompletion in [true, false]) {
    for (final continuous in [true, false]) {
      testWidgets('podcast native completion respects continuous=$continuous '
          'when paused=$pausedBeforeCompletion', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await tester.runAsync(settings.init);
        settings.autoPlayOnCompletion = !continuous;
        settings.playlistWrapToFirst = false;
        final originalPlatform = VideoPlayerPlatform.instance;
        final platform = _PodcastPlatform();
        VideoPlayerPlatform.instance = platform;
        final playback = MediaPlaybackService.forTesting();
        final playlist = PlaylistManager();
        final heard = <String>{};
        final checkpoints = <(String, int, bool?)>[];
        PodcastPlaybackHooks.resolve = (_) async =>
            Uri.parse('http://127.0.0.1:47790/media');
        PodcastPlaybackHooks.continuous = (_) => continuous;
        PodcastPlaybackHooks.completed = (item) => heard.add(item.id);
        PodcastPlaybackHooks.syncedProgress = (item, position, completed, _) {
          checkpoints.add((item.id, position, completed));
          if (completed == false) heard.remove(item.id);
        };
        final items = [
          for (final id in ['first', 'second'])
            VideoItem(
              id: id,
              path: 'podcast:$id',
              title: id,
              durationMs: 120000,
              lastUpdated: 1,
              type: MediaType.audio,
              sourceRef: MediaSourceRef(
                value: 'podcast:$id',
                kind: MediaSourceKind.podcastEpisode,
                podcast: PodcastEpisodeRef(
                  channelId: 'channel',
                  episodeId: id,
                  feedUrl: 'https://example.com/rss',
                  mediaUrl: 'https://example.com/$id.mp3',
                ),
              ),
            ),
        ];
        try {
          await _pumpPlayback(
            tester,
            playback.initialize(
              playlistManager: playlist,
              progressTracker: ProgressTracker(
                playbackStateStore: _MemoryPlaybackStateStore(),
              ),
            ),
          );
          playlist.setPlaylist(items);
          await _pumpPlayback(tester, playback.play(items.first));
          final firstController = playback.controller!;
          // Native completion pauses before video_player publishes its final
          // seek. The service clock can still be one sample short of EOF.
          platform.positions[platform.events.keys.single] = const Duration(
            seconds: 119,
          );
          firstController.value = firstController.value.copyWith(
            position: const Duration(seconds: 119),
          );
          playback.updatePlaybackStateFromController();
          if (pausedBeforeCompletion) {
            await _pumpPlayback(tester, playback.pause());
          }
          platform.events.values.single.add(
            VideoEvent(eventType: VideoEventType.completed),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(heard, contains('first'));
          expect(playback.currentItem?.id, continuous ? 'second' : 'first');
          if (continuous) {
            await _pumpPlayback(tester, () async {
              // Auto-advance is asynchronous. Await the real fake decoder
              // clock, not only the queue cursor moving to the next episode.
              while (playback.state == PlaybackState.loading) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            }());
            expect(playback.isPlaying, isTrue);
            expect(checkpoints, [('first', 0, null)]);
            // Accidentally replaying a heard episode changes only its current
            // bookmark. Leaving it again must preserve the listened history.
            await _pumpPlayback(
              tester,
              playback.playPlaylistItem(items.first, autoPlay: true),
            );
            expect(playback.position, lessThan(const Duration(seconds: 1)));
            final replayController = playback.controller!;
            platform.positions[platform.events.keys.single] = const Duration(
              seconds: 3,
            );
            replayController.value = replayController.value.copyWith(
              position: const Duration(seconds: 3),
            );
            playback.updatePlaybackStateFromController();
            await _pumpPlayback(
              tester,
              playback.playPlaylistItem(items.last, autoPlay: true),
            );
            expect(heard, contains('first'));
            expect(checkpoints.last, ('first', 3000, null));

            // An enabled switch still stops at the end of the queue when
            // list wrapping is disabled.
            platform.events.values.single.add(
              VideoEvent(eventType: VideoEventType.completed),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 150));
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(heard, containsAll(['first', 'second']));
            expect(playback.currentItem?.id, 'second');
            expect(playback.state, PlaybackState.paused);
            expect(playback.position, const Duration(minutes: 2));
            expect(playback.positionNotifier.value, playback.duration);
          } else {
            expect(playback.state, PlaybackState.paused);
            expect(playback.position, const Duration(minutes: 2));
            expect(playback.positionNotifier.value, playback.duration);
            expect(playback.controller, same(firstController));
          }
          final finishedController = playback.controller!;
          for (final sample in [
            const Duration(milliseconds: 119920),
            Duration.zero,
            const Duration(minutes: 2),
          ]) {
            finishedController.value = finishedController.value.copyWith(
              position: sample,
              isPlaying: false,
            );
            playback.updatePlaybackStateFromController();
            await tester.pump();
            expect(playback.state, PlaybackState.paused);
            expect(playback.position, const Duration(minutes: 2));
            expect(playback.positionNotifier.value, playback.duration);
            expect(playback.coarsePositionNotifier.value, playback.duration);
          }
        } finally {
          await _pumpPlayback(tester, playback.stop());
          playback.dispose();
          VideoPlayerPlatform.instance = originalPlatform;
          PodcastPlaybackHooks.resolve = null;
          PodcastPlaybackHooks.continuous = null;
          PodcastPlaybackHooks.completed = null;
          PodcastPlaybackHooks.syncedProgress = null;
          settings.resetForTest();
        }
      });
    }
  }
  testWidgets('episode entry covers the library before changing the session', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService.forTesting();
    final playlist = PlaylistManager();
    final library = LibraryService()..resetLibraryForTesting();
    final store = PodcastStore(sqlite3.openInMemory());
    final root = Directory.systemTemp.createTempSync('podcast-entry-');
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
    final feed = client.parser.parse(
      utf8.encode(podcastFixture()),
      'https://example.com/rss',
    );
    store.mergeFeed(feed, initial: true);
    final runtime = PodcastRuntime.forTesting(
      controller,
      playback: playback,
      playlist: playlist,
    );
    PodcastRuntime.debugOverride = runtime;
    final observer = PlaybackRouteObserver();
    final gate = Completer<void>();
    final resolving = Completer<void>();
    playback.beforeLibraryPlayback = (_) {
      if (!resolving.isCompleted) resolving.complete();
      return gate.future;
    };
    final openedOverPlayer = <bool>[];
    runtime.addListener(() {
      if (runtime.openingEpisodeId != null) {
        openedOverPlayer.add(
          observer.topRoute?.settings.name == '/playback/podcast',
        );
      }
    });
    try {
      await tester.runAsync(settings.init);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<TranscriptionManager>.value(
              value: TranscriptionManager(),
            ),
            ChangeNotifierProvider<EmbeddedSubtitleService>.value(
              value: EmbeddedSubtitleService(),
            ),
            ChangeNotifierProvider<OcrSubtitleManager>(
              create: (_) => OcrSubtitleManager(library: library),
            ),
          ],
          child: MaterialApp(
            navigatorObservers: [observer],
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      openPodcastEpisode(context, feed.episodes.first),
                  child: const Text('Open episode'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open episode'));
      expect(openedOverPlayer, isNotEmpty);
      expect(openedOverPlayer, everyElement(isTrue));
      await tester.runAsync(
        () => resolving.future.timeout(const Duration(seconds: 5)),
      );
      expect(
        playback.currentItem?.sourceRef?.podcast?.episodeId,
        feed.episodes.first.id,
      );
      await playback.cancelPendingPlay(keepBookmark: true);
    } finally {
      gate.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpPlayback(tester, playback.stop());
      await tester.runAsync(controller.close);
      runtime.dispose();
      playback.dispose();
      PodcastRuntime.debugOverride = null;
      store.close();
      await tester.runAsync(() => root.delete(recursive: true));
      settings.resetForTest();
      library.resetLibraryForTesting();
    }
  });
  testWidgets(
    'cold podcast waits for audio progress and a stalled start can retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await tester.runAsync(settings.init);
      final previousPlatform = VideoPlayerPlatform.instance;
      final previousResolve = PodcastPlaybackHooks.resolve;
      final platform = _PodcastPlatform()..advanceOnPlay = false;
      VideoPlayerPlatform.instance = platform;
      final playback = MediaPlaybackService.forTesting();
      final owner = Object();
      playback.setPlaybackPageVisible(owner, true);
      PodcastPlaybackHooks.resolve = (_) async =>
          Uri.parse('http://127.0.0.1/media');
      final item = VideoItem(
        id: 'cold-start',
        path: 'podcast:cold-start',
        title: '首次播放',
        durationMs: 120000,
        lastUpdated: 1,
        type: MediaType.audio,
        sourceRef: const MediaSourceRef(
          value: 'podcast:cold-start',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: 'cold-start',
            feedUrl: 'https://example.com/rss',
            mediaUrl: 'https://example.com/audio.mp3',
          ),
        ),
      );
      Future<void> waitForPlayCommand() async {
        for (var i = 0; i < 100 && platform.playing.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(platform.playing, isNotEmpty);
      }

      try {
        final opening = playback.play(item);
        await waitForPlayCommand();
        await tester.pump(const Duration(seconds: 2));
        expect(playback.controller!.value.isPlaying, isTrue);
        expect(playback.state, PlaybackState.loading);
        expect(playback.isPlaying, isFalse);
        platform.positions[platform.events.keys.single] = const Duration(
          milliseconds: 100,
        );
        await _pumpPlayback(tester, opening);
        expect(playback.state, PlaybackState.playing);

        await _pumpPlayback(tester, playback.stop());
        platform.playing.clear();
        final stalled = playback.play(item);
        await waitForPlayCommand();
        for (var i = 0; i < 130; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await _pumpPlayback(tester, stalled);
        expect(playback.state, PlaybackState.error);
        expect(playback.isPlaying, isFalse);
        expect(playback.controller, isNull);

        platform.advanceOnPlay = true;
        await _pumpPlayback(tester, playback.resume());
        expect(playback.state, PlaybackState.playing);
        expect(platform.sources, hasLength(3));
      } finally {
        await _pumpPlayback(tester, playback.stop());
        playback.setPlaybackPageVisible(owner, false);
        playback.dispose();
        VideoPlayerPlatform.instance = previousPlatform;
        PodcastPlaybackHooks.resolve = previousResolve;
        settings.resetForTest();
      }
    },
  );
  testWidgets(
    'video podcast starts in its final page before a session exists',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final playback = MediaPlaybackService.forTesting();
      final library = LibraryService()..resetLibraryForTesting();
      final playlist = PlaylistManager();
      final store = PodcastStore(sqlite3.openInMemory());
      final root = Directory.systemTemp.createTempSync('podcast-video-entry-');
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
      final feed = client.parser.parse(
        utf8.encode(
          podcastFixture()
              .replaceAll('.mp3', '.mp4')
              .replaceAll('audio/mpeg', 'video/mp4'),
        ),
        'https://example.com/rss',
      );
      store.mergeFeed(feed, initial: true);
      final runtime = PodcastRuntime.forTesting(
        controller,
        playback: playback,
        playlist: playlist,
      );
      PodcastRuntime.debugOverride = runtime;
      try {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<TranscriptionManager>.value(
                value: TranscriptionManager(),
              ),
              ChangeNotifierProvider<EmbeddedSubtitleService>.value(
                value: EmbeddedSubtitleService(),
              ),
              ChangeNotifierProvider<OcrSubtitleManager>(
                create: (_) => OcrSubtitleManager(library: library),
              ),
            ],
            child: MaterialApp(
              home: PodcastPlayerPage(episodeId: feed.episodes.first.id),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(MusicPlayerScreen), findsNothing);
        final page = tester.widget<VideoPlayerScreen>(
          find.byType(VideoPlayerScreen),
        );
        expect(page.videoItem?.type, MediaType.video);
        expect(page.deferPlaybackUntilCurrent, isTrue);
        expect(playback.currentItem, isNull);
        expect(playback.controller, isNull);
        expect(
          tester
              .state<VideoControlsOverlayState>(
                find.byType(VideoControlsOverlay),
              )
              .controlsVisible,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 30));
        await tester.runAsync(controller.close);
        runtime.dispose();
        playback.dispose();
        PodcastRuntime.debugOverride = null;
        store.close();
        await tester.runAsync(() => root.delete(recursive: true));
        settings.resetForTest();
        library.resetLibraryForTesting();
      }
    },
  );

  testWidgets(
    'podcast notes open separately from the full portrait and landscape transcript',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      final originalPlatform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = _PodcastPlatform();
      final playback = MediaPlaybackService.forTesting();
      final playlist = PlaylistManager();
      final store = PodcastStore(sqlite3.openInMemory());
      final root = Directory.systemTemp.createTempSync('podcast-player-');
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
      final storyParagraphs = List.filled(
        12,
        '这是一段可以展开阅读的节目简介，讲述本期的主题与故事。',
      ).join('\n');
      final description = '[00:00:44] 从这里继续收听本期故事\n\n$storyParagraphs';
      final feed = client.parser.parse(
        utf8.encode(
          podcastFixture().replaceFirst(
            '<title>第一集</title>',
            '<title>第一集</title><description>$description</description>',
          ),
        ),
        'https://example.com/rss',
      );
      final episode = feed.episodes.first;
      store.mergeFeed(feed, initial: true);
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        controller,
        playback: playback,
        playlist: playlist,
      );
      PodcastPlaybackHooks.resolve = (_) async =>
          Uri.parse('http://127.0.0.1:47790/audio');
      final item = VideoItem(
        id: 'podcast-test',
        path: 'podcast:${episode.id}',
        title: episode.title,
        durationMs: 120000,
        lastUpdated: 1,
        type: MediaType.audio,
        sourceRef: MediaSourceRef(
          value: 'podcast:${episode.id}',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: episode.channelId,
            episodeId: episode.id,
            feedUrl: feed.channel.feedUrl,
            mediaUrl: episode.media.first.url,
          ),
        ),
      );
      try {
        await tester.runAsync(settings.init);
        await tester.runAsync(() async {
          for (final font in {
            'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
            'Inter': 'assets/fonts/Inter-Regular.otf',
            'Noto Sans CJK Fallback': 'assets/fonts/NotoSansCJKsc-Regular.otf',
            'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
            'packages/cupertino_icons/CupertinoIcons':
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
          }.entries) {
            await (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load();
          }
        });
        await _pumpPlayback(
          tester,
          playback.initialize(
            playlistManager: playlist,
            progressTracker: ProgressTracker(
              playbackStateStore: _MemoryPlaybackStateStore(),
            ),
          ),
        );
        playlist.setPlaylist([item]);
        await _pumpPlayback(
          tester,
          playback.play(item, startPosition: const Duration(seconds: 30)),
        );
        await _pumpPlayback(tester, playback.pause());
        playback.setSubtitleState(
          paths: const [],
          primary: List.generate(
            30,
            (index) => SubtitleItem(
              index: index,
              startTime: Duration(seconds: index * 4),
              endTime: Duration(seconds: index * 4 + 4),
              text: [
                '把日常过成值得回味的故事。',
                '关于城市、远方和生活里的微小瞬间。',
                '当我们不再急着抵达，路上会多出怎样的风景？',
              ][index % 3],
            ),
          ),
          secondary: const [],
        );
        final navigatorKey = GlobalKey<NavigatorState>();
        final previewKey = GlobalKey();
        Future<void> capture(String name) => tester.runAsync(() async {
          final boundary =
              previewKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final folder = Directory('.artifacts/podcast-previews')
            ..createSync(recursive: true);
          await File(
            '${folder.path}/reader-$name.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        late BuildContext libraryContext;
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ],
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: ThemeData(
                brightness: Brightness.dark,
                fontFamily: 'Noto Sans SC',
                fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans CJK Fallback'],
              ),
              builder: (_, child) =>
                  RepaintBoundary(key: previewKey, child: child!),
              home: MediaLibraryShell(
                home: Builder(
                  builder: (context) {
                    libraryContext = context;
                    return Scaffold(
                      body: TextButton(
                        onPressed: () => openPodcastEpisode(context, episode),
                        child: const Text('打开播客'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(settings.showMiniPlaybackCard, isTrue);
        expect(find.byType(MiniPlaybackCard), findsOneWidget);
        final nativeController = playback.controller;
        await tester.tap(find.text('打开播客'));
        await tester.pumpAndSettle();
        expect(navigatorKey.currentState!.canPop(), isTrue);
        expect(
          MediaLibraryShell.maybeOf(libraryContext)!.libraryNavigator!.canPop(),
          isFalse,
        );
        expect(find.byType(MiniPlaybackCard), findsNothing);
        expect(
          find.byKey(const ValueKey('music-landscape-toolbar')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('podcast-inline-show-notes')),
          findsNothing,
        );
        final portraitHeader = find.byKey(
          const ValueKey('music-portrait-header'),
        );
        expect(tester.getTopLeft(portraitHeader).dy, closeTo(4, 1));
        expect(
          find.descendant(of: portraitHeader, matching: find.byTooltip('关闭')),
          findsOneWidget,
        );
        // The paused fixture is at 30s, inside cue 7 (28s–32s). Check its
        // rendered position instead of a fixed anchor: the reading area adapts
        // to the header, system safe area and text size.
        Rect expectPortraitFocusClear() {
          final header = tester.getRect(portraitHeader);
          final controls = tester.getRect(find.byType(MusicPlaybackControls));
          final lyrics = find.byType(MusicLyricView);
          final viewport = tester.getRect(lyrics);
          final insets = tester.widget<MusicLyricView>(lyrics).focusInsets!;
          final readableTop = viewport.top + insets.top;
          final readableBottom = viewport.bottom - insets.bottom;
          final currentLine = tester.getRect(
            find
                .descendant(
                  of: find.byKey(const ValueKey('music-lyric-row-opacity-7')),
                  matching: find.byType(MusicTimedLyricText),
                )
                .first,
          );
          expect(currentLine.top, greaterThan(header.bottom + 24));
          expect(readableBottom, lessThan(controls.top - 24));
          // Text uses a small optical alignment offset inside the lyric row.
          const opticalTolerance = 2.0;
          expect(
            currentLine.top,
            greaterThanOrEqualTo(readableTop - opticalTolerance),
          );
          if (currentLine.height <= readableBottom - readableTop) {
            expect(
              currentLine.bottom,
              lessThanOrEqualTo(readableBottom + opticalTolerance),
            );
          } else {
            // Oversized paragraphs start at the readable top; their remaining
            // lines stay accessible by scrolling instead of shrinking the text.
            expect(currentLine.top, closeTo(readableTop, opticalTolerance));
            expect(
              tester
                  .stateList<ScrollableState>(
                    find.descendant(
                      of: lyrics,
                      matching: find.byType(Scrollable),
                    ),
                  )
                  .any((scroll) => scroll.position.maxScrollExtent > 0),
              isTrue,
            );
          }
          return currentLine;
        }

        final portraitFocus = expectPortraitFocusClear();
        final toggle = find.byKey(const ValueKey('podcast-description-toggle'));
        final close = find.descendant(
          of: portraitHeader,
          matching: find.byKey(const ValueKey('music-toolbar-close')),
        );
        expect(
          tester.getTopLeft(toggle).dx,
          greaterThan(tester.getTopLeft(close).dx),
        );
        final more = find.byTooltip('播客设置与节目操作');
        final metadata = find.byKey(const ValueKey('music-portrait-metadata'));
        expect(tester.getSize(close), const Size(44, 44));
        expect(tester.getSize(more), tester.getSize(close));
        expect(tester.getRect(close).left, tester.getRect(metadata).left);
        final tools = tester.getRect(
          find.byKey(const ValueKey('music-portrait-tools')),
        );
        expect(tools.right, tester.getRect(metadata).right);
        expect(tester.getRect(more).right, tools.right - 2);
        expect(tester.getCenter(more).dy, tester.getCenter(close).dy);
        expect(
          tester.getRect(metadata).top - tester.getRect(close).bottom,
          inInclusiveRange(8, 12),
        );
        expect(tools.left, greaterThan(tester.getRect(close).right));
        expect(
          tester.getTopRight(toggle).dx,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('music-toolbar-ai-chat')))
                .dx,
          ),
        );
        expect(find.text('节目简介'), findsNothing);
        final portraitPicker = find.byKey(
          const ValueKey('music-episode-picker-button'),
        );
        expect(
          find.descendant(of: portraitHeader, matching: portraitPicker),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(MusicPlaybackControls),
            matching: portraitPicker,
          ),
          findsNothing,
        );
        expect(find.text('选集'), findsNothing);
        expect(
          tester.getCenter(portraitPicker).dy,
          closeTo(tester.getCenter(close).dy, 1),
        );
        final portraitLyricBounds = tester.getRect(find.byType(MusicLyricView));
        expect(
          portraitLyricBounds.top,
          greaterThan(tester.getRect(portraitHeader).bottom),
        );
        expect(portraitLyricBounds.bottom, closeTo(844, 1));
        await capture('phone-collapsed');
        await tester.pump(const Duration(seconds: 6));
        await tester.pump(const Duration(seconds: 1));
        await capture('phone-controls-hidden');
        expect(
          tester.getRect(find.byType(MusicLyricView)),
          portraitLyricBounds,
        );
        expect(expectPortraitFocusClear(), portraitFocus);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('podcast-show-notes')),
          findsOneWidget,
        );
        await capture('phone-expanded');
        expect(find.text('点击时间或条目跳转播放'), findsOneWidget);
        await tester.tap(find.text('00:00:44'));
        await tester.pumpAndSettle();
        expect(playback.position, const Duration(seconds: 44));
        final notesPlatform = VideoPlayerPlatform.instance as _PodcastPlatform;
        expect(
          notesPlatform.positions.values.single,
          const Duration(seconds: 44),
        );
        expect(playback.isPlaying, isFalse);
        expect(
          find.byKey(const ValueKey('podcast-show-notes')),
          findsOneWidget,
        );
        await _pumpPlayback(
          tester,
          playback.seekTo(const Duration(seconds: 30)),
        );
        await tester.pumpAndSettle();
        await capture('timestamp-seek-phone');
        final portraitNotes = tester.getRect(
          find.byKey(const ValueKey('podcast-show-notes')),
        );
        expect(portraitNotes.bottom, closeTo(844 - 12, 1));
        expect(portraitNotes.left, 12);
        expect(portraitNotes.right, 390 - 12);
        expect(portraitNotes.height, lessThanOrEqualTo(844 * .72 + 1));
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(320, 640);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final dispatcher = tester.platformDispatcher;
        dispatcher.textScaleFactorTestValue = 1.7;
        addTearDown(dispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(close).left, tester.getRect(metadata).left);
        expect(tester.getRect(more).right, tester.getRect(metadata).right - 2);
        expect(tester.getRect(close).top, greaterThanOrEqualTo(24));
        await capture('small-safe-area');
        expectPortraitFocusClear();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final smallNotes = tester.getRect(
          find.byKey(const ValueKey('podcast-show-notes')),
        );
        expect(smallNotes.left, 12);
        expect(smallNotes.right, 320 - 12);
        expect(smallNotes.bottom, lessThanOrEqualTo(640 - 24));
        expect(tester.takeException(), isNull);
        await capture('small-safe-area-expanded');
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        dispatcher.clearTextScaleFactorTestValue();
        await tester.pumpAndSettle();
        store.write('episode', episode.id, {
          ...episode.toJson(),
          'description': '一次关于城市和远方的简短对话。',
        }, channel: episode.channelId);
        controller.reload();
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final shortPortraitNotes = tester.getRect(
          find.byKey(const ValueKey('podcast-show-notes')),
        );
        final shortPortraitScroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('podcast-notes-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(shortPortraitNotes.bottom, closeTo(844 - 12, 1));
        expect(shortPortraitNotes.height, lessThan(portraitNotes.height));
        expect(shortPortraitNotes.height, lessThan(844 * .4));
        expect(shortPortraitScroll.position.maxScrollExtent, 0);
        await capture('phone-short-notes');
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();
        store.write('episode', episode.id, {
          ...episode.toJson(),
          'description': List.filled(40, '这是一段需要滚动才能读完的节目简介。').join('\n'),
        }, channel: episode.channelId);
        controller.reload();
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final cappedPortraitNotes = tester.getRect(
          find.byKey(const ValueKey('podcast-show-notes')),
        );
        final cappedPortraitScroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('podcast-notes-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(cappedPortraitNotes.height, closeTo(844 * .72, 1));
        expect(cappedPortraitNotes.bottom, closeTo(844 - 12, 1));
        expect(cappedPortraitScroll.position.maxScrollExtent, greaterThan(24));
        await tester.drag(
          find.byKey(const ValueKey('podcast-notes-scroll')),
          const Offset(0, -160),
        );
        await tester.pumpAndSettle();
        expect(cappedPortraitScroll.position.pixels, greaterThan(0));
        expect(
          tester
              .getRect(find.byKey(const ValueKey('podcast-show-notes')))
              .height,
          closeTo(cappedPortraitNotes.height, 1),
        );
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();
        store.write('episode', episode.id, {
          ...episode.toJson(),
          'description': description,
        }, channel: episode.channelId);
        controller.reload();
        await tester.pumpAndSettle();
        final primary = List<SubtitleItem>.of(playback.subtitles);
        playback.setSubtitleState(paths: [], primary: [], secondary: []);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 10));
        final controls = find.byKey(
          const ValueKey('music-portrait-controls-overlay'),
        );
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .descendant(
                      of: controls,
                      matching: find.byType(IgnorePointer),
                    )
                    .first,
              )
              .ignoring,
          isFalse,
        );
        await capture('phone-no-subtitles');
        final native = VideoPlayerPlatform.instance as _PodcastPlatform;
        final playerId = native.events.keys.single;
        await _pumpPlayback(tester, playback.resume());
        native.events[playerId]!.add(
          VideoEvent(eventType: VideoEventType.bufferingStart),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1100));
        await tester.pump(const Duration(milliseconds: 180));
        expect(
          tester
              .widget<MusicPlayerScreen>(find.byType(MusicPlayerScreen))
              .isLoading,
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('music-playback-loading')),
          findsOneWidget,
        );
        await capture('phone-buffering');
        native.events[playerId]!.add(
          VideoEvent(eventType: VideoEventType.bufferingEnd),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        expect(
          tester
              .widget<MusicPlayerScreen>(find.byType(MusicPlayerScreen))
              .isLoading,
          isFalse,
        );
        expect(
          find.byKey(const ValueKey('music-playback-loading')),
          findsNothing,
        );
        await _pumpPlayback(tester, playback.pause());
        playback.setSubtitleState(paths: [], primary: primary, secondary: []);
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(1100, 844);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('podcast-show-notes')), findsNothing);
        expect(find.byType(MusicLyricView), findsOneWidget);
        final landscapeBounds = tester.getRect(find.byType(MusicLyricView));
        expect(landscapeBounds.height, closeTo(844, 1));
        final toolbar = find.byKey(const ValueKey('music-landscape-toolbar'));
        final toolbarBounds = tester.getRect(toolbar);
        expect(toolbarBounds.right, lessThan(550));
        expect(toolbarBounds.left, 16);
        expect(toolbarBounds.top, 16);
        expect(
          tester
              .widgetList<Icon>(
                find.descendant(of: toolbar, matching: find.byType(Icon)),
              )
              .map((icon) => icon.icon),
          [
            Icons.close_rounded,
            Icons.fullscreen,
            Icons.more_horiz_rounded,
            Icons.auto_awesome_outlined,
            Icons.schedule_rounded,
            Icons.queue_music_rounded,
            Icons.notes_rounded,
          ],
        );
        final buttons = find.descendant(
          of: toolbar,
          matching: find.byType(IconButton),
        );
        expect(buttons, findsNWidgets(6));
        expect(find.byTooltip('播客设置与节目操作'), findsOneWidget);
        for (final button in buttons.evaluate()) {
          final bounds = tester.getRect(find.byWidget(button.widget));
          expect(bounds.width, closeTo(44, .01));
          expect(bounds.height, closeTo(44, .01));
          expect(bounds.center.dy, closeTo(toolbarBounds.center.dy, .5));
        }

        await capture('desktop-collapsed');
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        final popover = find.byKey(const ValueKey('podcast-notes-popover'));
        final longDesktopNotes = tester.getRect(popover);
        expect(longDesktopNotes.left, tester.getTopLeft(toolbar).dx);
        expect(longDesktopNotes.top, tester.getBottomLeft(toolbar).dy + 4);
        expect(longDesktopNotes.width, 420);
        expect(longDesktopNotes.bottom, lessThanOrEqualTo(844 - 16));
        expect(tester.getRect(find.byType(MusicLyricView)), landscapeBounds);
        await capture('desktop-expanded');
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(MusicLyricView)), landscapeBounds);
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('podcast-inline-show-notes')),
          findsNothing,
        );
        final mobileLandscapeBounds = tester.getRect(
          find.byType(MusicLyricView),
        );
        expect(mobileLandscapeBounds.height, closeTo(390, 1));
        expect(tester.getTopLeft(toolbar).dx, 16);
        expect(tester.getTopLeft(toolbar).dy, closeTo(16, 1));
        expect(tester.getRect(toolbar).right, lessThan(422));
        expect(
          tester
              .getBottomLeft(
                find.byKey(const ValueKey('music-episode-picker-button')),
              )
              .dy,
          lessThanOrEqualTo(390),
        );
        await capture('landscape-phone-collapsed');
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('podcast-show-notes')),
          findsOneWidget,
        );
        final longMobileNotes = tester.getRect(popover);
        expect(longMobileNotes.top, tester.getBottomLeft(toolbar).dy + 4);
        expect(longMobileNotes.bottom, lessThanOrEqualTo(390 - 16));
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('podcast-notes-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        await capture('landscape-phone-expanded');
        final collapse = find.byKey(
          const ValueKey('podcast-description-collapse'),
        );
        final collapseBounds = tester.getRect(collapse);
        await tester.drag(
          find.byKey(const ValueKey('podcast-notes-scroll')),
          const Offset(0, -180),
        );
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(tester.getRect(collapse), collapseBounds);
        expect(tester.getRect(popover), longMobileNotes);
        expect(
          tester.getRect(find.byType(MusicLyricView)),
          mobileLandscapeBounds,
        );
        await tester.tap(
          find.byKey(const ValueKey('podcast-description-collapse')),
        );
        await tester.pumpAndSettle();

        // A one-line note should size to its content rather than fill a sheet.
        store.write('episode', episode.id, {
          ...episode.toJson(),
          'description': '一次关于城市和远方的简短对话。',
        }, channel: episode.channelId);
        controller.reload();
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final shortMobileNotes = tester.getRect(popover);
        expect(shortMobileNotes.height, lessThan(longMobileNotes.height));
        expect(shortMobileNotes.height, lessThan(200));
        expect(shortMobileNotes.top, tester.getBottomLeft(toolbar).dy + 4);
        await capture('landscape-phone-short-notes');
        expect(
          tester.getRect(find.byType(MusicLyricView)),
          mobileLandscapeBounds,
        );
        // Tapping the page outside the card collapses it without leaving playback.
        await tester.tapAt(const Offset(800, 350));
        await tester.pumpAndSettle();
        expect(popover, findsNothing);
        expect(
          tester.getRect(find.byType(MusicLyricView)),
          mobileLandscapeBounds,
        );

        tester.view.physicalSize = const Size(1100, 844);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(popover).height,
          lessThan(longDesktopNotes.height),
        );
        expect(tester.getRect(popover).height, lessThan(200));
        await capture('desktop-short-notes');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(popover, findsNothing);
        expect(playback.controller, same(nativeController));
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(MiniPlaybackCard), findsOneWidget);
        expect(playback.controller, same(nativeController));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpPlayback(tester, playback.stop());
        PodcastRuntime.debugOverride = null;
        PodcastPlaybackHooks.resolve = null;
        VideoPlayerPlatform.instance = originalPlatform;
        await tester.runAsync(controller.close);
        store.close();
        root.deleteSync(recursive: true);
        settings.resetForTest();
      }
    },
  );
  testWidgets(
    'shared music metadata fits small podcast screens at large text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService()..resetForTest(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: MediaPlaybackService.forTesting(),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.7)),
              child: child!,
            ),
            home: const MusicPlayerScreen(
              title: '一个很长的中文播客节目标题',
              artist: '播客频道与主播',
              followCurrentSession: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('music-episode-picker-button')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'shared music picker keeps the controller across phone and desktop layouts',
    (tester) async {
      for (final width in [390.0, 1100.0]) {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        final originalPlatform = VideoPlayerPlatform.instance;
        final platform = _PodcastPlatform();
        VideoPlayerPlatform.instance = platform;
        final playback = MediaPlaybackService.forTesting(),
            playlist = PlaylistManager();
        final resumeStore = _MemoryPlaybackStateStore();
        VideoItem item(String id, String title, int position) => VideoItem(
          id: id,
          path: 'podcast:$id',
          title: title,
          durationMs: 120000,
          lastUpdated: 1,
          lastPositionMs: position,
          type: MediaType.audio,
          sourceRef: MediaSourceRef(
            value: 'podcast:$id',
            kind: MediaSourceKind.podcastEpisode,
            podcast: PodcastEpisodeRef(
              channelId: 'channel',
              episodeId: id,
              feedUrl: 'https://example.com/rss',
              mediaUrl: 'https://example.com/$id.mp3',
            ),
          ),
        );
        final first = item('one', '第一集', 30000),
            second = item('two', '第二集', 45000);
        PodcastPlaybackHooks.resolve = (item) async =>
            Uri.parse('http://127.0.0.1:47790/${item.id}');
        try {
          await tester.runAsync(settings.init);
          await _pumpPlayback(tester, () async {
            await playback.cancelPendingPlay();
            await playback.initialize(
              playlistManager: playlist,
              progressTracker: ProgressTracker(playbackStateStore: resumeStore),
            );
            playlist.setPlaylist([first, second], currentItemId: first.id);
            await playback.play(
              first,
              startPosition: const Duration(seconds: 30),
            );
          }());
          final controller = playback.controller;
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsService>.value(value: settings),
                ChangeNotifierProvider<MediaPlaybackService>.value(
                  value: playback,
                ),
                ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ],
              child: const MaterialApp(home: MusicPlayerScreen()),
            ),
          );
          await tester.pump();
          expect(playback.controller, same(controller));
          expect(playback.position.inSeconds, 30);
          await tester.tap(
            find.byKey(const ValueKey('music-episode-picker-button')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(find.byType(EpisodePickerPanel), findsOneWidget);
          expect(platform.sources, hasLength(1));
          final row = find.descendant(
            of: find.byType(EpisodePickerPanel),
            matching: find.text('第二集'),
          );
          await tester.tap(row);
          for (
            var i = 0;
            i < 100 &&
                (playback.currentItem?.id != second.id ||
                    !playback.isPlaying ||
                    resumeStore.snapshot?['currentItemId'] != second.id);
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await tester.pump();
          expect(playback.currentItem?.id, second.id);
          expect(playback.position.inSeconds, 45);
          expect(playlist.playlist.map((e) => e.id), ['one', 'two']);
          expect(find.byType(EpisodePickerPanel), findsOneWidget);
          expect(platform.sources, hasLength(2));
          await tester.tap(row);
          await tester.pump();
          expect(platform.sources, hasLength(2));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          var stopped = false;
          final stopping = playback
              .cancelPendingPlay()
              .then((_) => playback.stop())
              .whenComplete(() => stopped = true);
          for (var i = 0; i < 100 && !stopped; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          await stopping;
          VideoPlayerPlatform.instance = originalPlatform;
          PodcastPlaybackHooks.resolve = null;
          settings.resetForTest();
        }
      }
    },
  );
  testWidgets(
    'podcast subtitles wait for audio during loading, buffering and seek',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await tester.runAsync(settings.init);
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _PodcastPlatform();
      VideoPlayerPlatform.instance = platform;
      final playback = MediaPlaybackService.forTesting();
      final playlist = PlaylistManager();
      await _pumpPlayback(tester, playback.cancelPendingPlay());
      await _pumpPlayback(
        tester,
        playback.initialize(
          playlistManager: playlist,
          progressTracker: ProgressTracker(
            playbackStateStore: _MemoryPlaybackStateStore(),
          ),
        ),
      );
      PodcastPlaybackHooks.resolve = (_) async =>
          Uri.parse('http://127.0.0.1:47790/media');
      final cues = List.generate(
        60,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 2),
          endTime: Duration(seconds: index * 2 + 2),
          text: '字幕 $index',
        ),
      );
      Future<void> frames(Duration duration) async {
        for (
          var elapsed = 0;
          elapsed < duration.inMilliseconds;
          elapsed += 50
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      void expectActiveCue(int index) {
        final active = tester
            .widgetList<MusicLyricDepth>(find.byType(MusicLyricDepth))
            .where((row) => row.active)
            .toList();
        expect(active, hasLength(1));
        expect(
          find.descendant(
            of: find.byWidget(active.single),
            matching: find.text('字幕 $index'),
          ),
          findsOneWidget,
        );
      }

      try {
        for (final type in [MediaType.audio, MediaType.video]) {
          final item = VideoItem(
            id: 'waiting-${type.name}',
            path: 'podcast:waiting',
            title: '缓冲中的播客',
            durationMs: 120000,
            lastUpdated: 1,
            type: type,
            sourceRef: const MediaSourceRef(
              value: 'podcast:waiting',
              kind: MediaSourceKind.podcastEpisode,
              podcast: PodcastEpisodeRef(
                channelId: 'channel',
                episodeId: 'waiting',
                feedUrl: 'https://example.com/rss',
                mediaUrl: 'https://example.com/media.mp3',
              ),
            ),
          );
          playlist.setPlaylist([item]);
          platform.advanceOnPlay = true;
          await _pumpPlayback(
            tester,
            playback.play(item, startPosition: const Duration(seconds: 30)),
          );
          platform.advanceOnPlay = false;
          final playerId = platform.events.keys.single;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MusicLyricView(
                  subtitles: cues,
                  positionListenable: playback.positionNotifier,
                ),
              ),
            ),
          );
          // Audio started, but the native clock now stalls despite playing.
          expect(playback.isPlaying, isTrue);
          await frames(const Duration(seconds: 10));
          expect(playback.positionNotifier.value, const Duration(seconds: 30));
          expectActiveCue(15);

          platform.positions[playerId] = const Duration(milliseconds: 30100);
          await frames(const Duration(milliseconds: 400));
          expect(
            playback.positionNotifier.value,
            greaterThan(const Duration(seconds: 30)),
          );
          var bufferingNotifications = 0;
          void onBuffering() => bufferingNotifications++;
          playback.addListener(onBuffering);
          platform.events[playerId]!.add(
            VideoEvent(eventType: VideoEventType.bufferingStart),
          );
          await frames(const Duration(seconds: 10));
          expect(
            bufferingNotifications,
            greaterThan(0),
            reason:
                'A stationary buffering controller must update loading chrome',
          );
          playback.removeListener(onBuffering);
          expect(
            playback.positionNotifier.value,
            const Duration(milliseconds: 30100),
          );
          expectActiveCue(15);

          // bufferingEnd can arrive before the decoder actually resumes.
          platform.events[playerId]!.add(
            VideoEvent(eventType: VideoEventType.bufferingEnd),
          );
          await frames(const Duration(seconds: 5));
          expect(
            playback.positionNotifier.value,
            const Duration(milliseconds: 30100),
          );
          platform.positions[playerId] = const Duration(milliseconds: 30200);
          await frames(const Duration(milliseconds: 200));
          expect(
            playback.positionNotifier.value.inMilliseconds,
            inInclusiveRange(30200, 30800),
          );

          // A silent stall without any buffering notification is bounded too.
          await frames(const Duration(seconds: 10));
          final stalledPosition = playback.positionNotifier.value;
          await frames(const Duration(seconds: 5));
          expect(playback.positionNotifier.value, stalledPosition);
          expectActiveCue(15);

          platform.seekGate = Completer<void>();
          final seek = playback.seekTo(const Duration(seconds: 44));
          await frames(const Duration(seconds: 1));
          expect(playback.positionNotifier.value, const Duration(seconds: 44));
          expectActiveCue(22);
          platform.seekGate!.complete();
          await _pumpPlayback(tester, seek);
          platform.seekGate = null;
          await frames(const Duration(seconds: 5));
          expect(playback.positionNotifier.value, const Duration(seconds: 44));
          expectActiveCue(22);

          platform.positions[playerId] = const Duration(milliseconds: 44100);
          await frames(const Duration(milliseconds: 250));
          expect(
            playback.positionNotifier.value.inMilliseconds,
            inInclusiveRange(44100, 44700),
          );
          expectActiveCue(22);
          if (type == MediaType.audio) {
            final pendingSource = Completer<Uri>();
            PodcastPlaybackHooks.resolve = (_) => pendingSource.future;
            final nextItem = VideoItem(
              id: 'next-podcast',
              path: 'podcast:next',
              title: '正在连接的下一集',
              durationMs: 120000,
              lastUpdated: 1,
              type: MediaType.audio,
              sourceRef: const MediaSourceRef(
                value: 'podcast:next',
                kind: MediaSourceKind.podcastEpisode,
                podcast: PodcastEpisodeRef(
                  channelId: 'channel',
                  episodeId: 'next',
                  feedUrl: 'https://example.com/rss',
                  mediaUrl: 'https://example.com/next.mp3',
                ),
              ),
            );
            final sourceCount = platform.sources.length;
            playlist.setPlaylist([item, nextItem]);
            final switching = playback.play(
              nextItem,
              startPosition: const Duration(seconds: 12),
            );
            // A late callback from the old episode must not move the new
            // episode's subtitles while its media URL is still resolving.
            platform.positions[playerId] = const Duration(seconds: 55);
            platform.events[playerId]?.add(
              VideoEvent(eventType: VideoEventType.bufferingEnd),
            );
            await frames(const Duration(seconds: 1));
            expect(playback.currentItem?.id, nextItem.id);
            expect(
              playback.positionNotifier.value,
              const Duration(seconds: 12),
            );
            expectActiveCue(6);
            pendingSource.complete(Uri.parse('http://127.0.0.1:47790/next'));
            platform.advanceOnPlay = true;
            await _pumpPlayback(tester, switching);
            platform.advanceOnPlay = false;
            expect(platform.sources.length, sourceCount + 1);
            await frames(const Duration(seconds: 3));
            expect(
              playback.positionNotifier.value,
              const Duration(seconds: 12),
            );
            expectActiveCue(6);
            PodcastPlaybackHooks.resolve = (_) async =>
                Uri.parse('http://127.0.0.1:47790/media');
          }
          await tester.pumpWidget(const SizedBox());
          await _pumpPlayback(tester, playback.stop());
        }
      } finally {
        if (platform.seekGate?.isCompleted == false) {
          platform.seekGate!.complete();
        }
        await tester.pumpWidget(const SizedBox());
        await _pumpPlayback(tester, playback.cancelPendingPlay());
        await _pumpPlayback(tester, playback.stop());
        VideoPlayerPlatform.instance = originalPlatform;
        PodcastPlaybackHooks.resolve = null;
        settings.resetForTest();
      }
    },
  );
  testWidgets(
    'podcast uses the shared network player and session speed without modifying global settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await tester.runAsync(settings.init);
      final originalSpeed = settings.playbackSpeed;
      final originalPlatform = VideoPlayerPlatform.instance,
          platform = _PodcastPlatform();
      VideoPlayerPlatform.instance = platform;
      final playback = MediaPlaybackService.forTesting(),
          playlist = PlaylistManager();
      await _pumpPlayback(tester, playback.cancelPendingPlay());
      await _pumpPlayback(
        tester,
        playback.initialize(
          playlistManager: playlist,
          progressTracker: ProgressTracker(
            playbackStateStore: _MemoryPlaybackStateStore(),
          ),
        ),
      );
      PodcastPlaybackHooks.resolve = (_) async =>
          Uri.parse('http://127.0.0.1:47790/media');
      PodcastPlaybackHooks.speed = (_) => 1.75;
      final preparedSeeks = <String>[];
      PodcastPlaybackHooks.prepareSeek = (item) => preparedSeeks.add(item.id);
      final item = VideoItem(
        id: 'episode',
        path: 'podcast:episode',
        title: '播客',
        durationMs: 120000,
        lastUpdated: 1,
        type: MediaType.audio,
        sourceRef: const MediaSourceRef(
          value: 'podcast:episode',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: 'episode',
            feedUrl: 'https://example.com/rss',
            mediaUrl: 'https://example.com/audio.mp3',
          ),
        ),
      );
      playlist.setPlaylist([item]);
      try {
        await _pumpPlayback(
          tester,
          playback.play(item, startPosition: const Duration(seconds: 30)),
        );
        expect(playback.isSourceMissing, isFalse);
        expect(platform.sources.single.sourceType, DataSourceType.network);
        expect(platform.sources.single.uri, 'http://127.0.0.1:47790/media');
        expect(
          platform.sources.single.httpHeaders[PodcastPlaybackPolicy
              .streamHeader],
          'audio',
        );
        expect(platform.speeds, contains(1.75));
        expect(playback.position.inSeconds, 30);
        expect(settings.playbackSpeed, originalSpeed);
        preparedSeeks.clear();
        await _pumpPlayback(
          tester,
          playback.seekTo(const Duration(seconds: 45)),
        );
        expect(preparedSeeks, [item.id]);
        expect(playback.position.inSeconds, 45);
        await tester.pump(const Duration(milliseconds: 250));
        final controller = playback.controller;
        await _pumpPlayback(tester, playback.pause());
        await _pumpPlayback(tester, playback.resume());
        expect(identical(controller, playback.controller), isTrue);
        expect(platform.sources.length, 1);
      } finally {
        await _pumpPlayback(tester, playback.cancelPendingPlay());
        await _pumpPlayback(tester, playback.stop());
        VideoPlayerPlatform.instance = originalPlatform;
        PodcastPlaybackHooks.resolve = null;
        PodcastPlaybackHooks.speed = null;
        PodcastPlaybackHooks.prepareSeek = null;
        settings.resetForTest();
      }
    },
  );
}
