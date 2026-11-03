import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/main.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_restore_preview.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late MediaPlaybackService playback;
  late PlaylistManager playlist;
  late ProgressTracker progress;
  final saved = PlaybackStateSnapshot(
    currentItemId: 'saved',
    positionMs: 42000,
    wasPlaying: true,
    timestamp: 10,
  );

  VideoItem item({String id = 'saved', MediaSourceKind? kind}) => VideoItem(
    id: id,
    path: switch (kind) {
      MediaSourceKind.bilibiliStream => 'bilibili://stream/BVoffline?cid=1',
      MediaSourceKind.cloudDrive => 'cloud-drive:offline',
      MediaSourceKind.podcastEpisode => 'podcast:offline',
      MediaSourceKind.url => 'https://example.invalid/offline.mp4',
      _ => 'local.mp4',
    },
    title: 'Saved title',
    durationMs: 120000,
    lastUpdated: 0,
    sourceRef: kind == null
        ? null
        : MediaSourceRef(
            kind: kind,
            value: 'saved-source',
            bvid: 'BVoffline',
            cid: 1,
          ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PlaybackStateStore.legacyKey: jsonEncode(saved.toJson()),
      'showMiniPlaybackCard': true,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    library = LibraryService()..resetLibraryForTesting();
    playback = MediaPlaybackService.forTesting();
    playlist = PlaylistManager(
      modeStore: PlaybackStateStore(
        platform: TargetPlatform.android,
        preferenceKey: 'playback_queue_modes',
      ),
    )..initialize(libraryService: library);
    progress = ProgressTracker(
      playbackStateStore: PlaybackStateStore(platform: TargetPlatform.android),
    );
  });

  tearDown(() async {
    await playback.stop();
    playback.dispose();
    progress.dispose();
    await playlist.flushPlaybackModes();
    playlist.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  Future<PlaybackRestorePreview?> restore({ProgressTracker? tracker}) =>
      restorePlaybackPreview(
        playback: playback,
        progress: tracker ?? progress,
        playlist: playlist,
        library: library,
      );

  for (final kind in <MediaSourceKind?>[
    null,
    MediaSourceKind.bilibiliStream,
    MediaSourceKind.cloudDrive,
    MediaSourceKind.podcastEpisode,
    MediaSourceKind.url,
  ]) {
    test(
      '$kind restores offline metadata without a decoder or network request',
      () async {
        final video = item(kind: kind);
        library.seedVideoForTesting(video);
        var networkRequests = 0;
        final preview = await HttpOverrides.runZoned(
          restore,
          createHttpClient: (_) {
            networkRequests++;
            throw StateError('Offline');
          },
        );
        expect(preview, isNotNull);
        expect(playback.currentItem, same(video));
        expect(playback.currentItem?.sourceRef, same(video.sourceRef));
        expect(playback.position, const Duration(seconds: 42));
        expect(playback.duration, const Duration(minutes: 2));
        expect(playback.state, PlaybackState.paused);
        expect(playback.controller, isNull);
        expect(playback.shouldShowMiniPlaybackCard, isTrue);
        expect(preview!.isCurrent(playback, playlist), isTrue);
        expect(networkRequests, 0);
      },
    );
  }

  test(
    'a newer saved library position wins over the playback snapshot',
    () async {
      library.seedVideoForTesting(
        item()
          ..lastPositionMs = 58000
          ..lastUpdated = 11,
      );
      await restore();
      expect(playback.position, const Duration(seconds: 58));
    },
  );

  test('deleted items and a cleared snapshot never recreate a card', () async {
    expect(await restore(), isNull);
    expect(playback.currentItem, isNull);
    library.seedVideoForTesting(item());
    await progress.savePlaybackState(
      PlaybackStateSnapshot(positionMs: 0, wasPlaying: false),
    );
    expect(await restore(), isNull);
    expect(playback.currentItem, isNull);
  });

  test(
    'a saved manual queue takes precedence over a stale playback snapshot',
    () async {
      final manual = item(id: 'manual', kind: MediaSourceKind.url);
      library.seedVideoForTesting(item());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'playback_queue_modes',
        jsonEncode({
          'activeManualQueue': {
            'key': 'manual:saved',
            'currentId': manual.id,
            'items': [manual.toJson()],
          },
        }),
      );
      expect(await restore(), isNull);
      expect(playlist.hasManualQueue, isTrue);
      expect(playlist.anchoredItemId, manual.id);
      expect(playback.currentItem, isNull);
    },
  );

  for (final action in ['select', 'stop', 'queue']) {
    test(
      'user $action during a delayed read cancels bookmark restoration',
      () async {
        library.seedVideoForTesting(item());
        final gate = Completer<PlaybackStateSnapshot?>();
        final pending = restore(tracker: _DelayedProgress(gate.future));
        if (action == 'select') {
          playback.publishRestoredSessionPreview(
            item(id: 'new'),
            Duration.zero,
          );
        } else if (action == 'stop') {
          await playback.stop();
        } else {
          playlist.setPlaylist([item(id: 'new', kind: MediaSourceKind.url)]);
        }
        gate.complete(saved);
        expect(await pending, isNull);
        expect(playback.currentItem?.id, action == 'select' ? 'new' : isNull);
      },
    );
  }

  test(
    'deferred restoration becomes stale after a new session or queue',
    () async {
      library.seedVideoForTesting(item());
      final preview = (await restore())!;
      playlist.setPlaylist([item(id: 'new', kind: MediaSourceKind.url)]);
      expect(preview.isCurrent(playback, playlist), isFalse);
      await playback.stop();
      expect(preview.isCurrent(playback, playlist), isFalse);
    },
  );

  testWidgets('the first home frame has Mini before deferred services start', (
    tester,
  ) async {
    library.seedVideoForTesting(item(kind: MediaSourceKind.bilibiliStream));
    var deferredStarted = false;
    // Android completes core initialization before runApp; desktop uses the
    // same core future inside AppStartupGate (covered by app_startup_gate_test).
    await tester.runAsync(restore);
    expect(deferredStarted, isFalse);
    await tester.pumpWidget(
      AppStartupGate(
        initiallyReady: true,
        initialize: () async => fail('Core state is already ready'),
        onReadyFirstFrame: () => deferredStarted = true,
        child: ChangeNotifierProvider<MediaPlaybackService>.value(
          value: playback,
          child: MaterialApp(
            home: Scaffold(
              bottomNavigationBar: MiniPlaybackCard(isVisible: true),
            ),
          ),
        ),
      ),
    );
    expect(deferredStarted, isTrue);
    expect(find.text('Saved title'), findsOneWidget);
    expect(find.text('00:42 / 02:00'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(playback.controller, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('early podcast play', () {
    late Future<Uri> Function(VideoItem)? previousResolve;
    setUp(() {
      previousResolve = PodcastPlaybackHooks.resolve;
      PodcastPlaybackHooks.resolve = null;
    });
    tearDown(() => PodcastPlaybackHooks.resolve = previousResolve);

    test(
      'waits for the installed resolver without delaying the card',
      () async {
        final sourceReady = Completer<void>();
        PodcastPlaybackHooks.deferResolveUntil(sourceReady.future);
        library.seedVideoForTesting(item(kind: MediaSourceKind.podcastEpisode));
        await restore();
        expect(playback.currentItem?.title, 'Saved title');
        expect(playback.controller, isNull);
        var resolved = false;
        final pending = PodcastPlaybackHooks.resolve!(playback.currentItem!);
        PodcastPlaybackHooks.resolve = (value) async {
          resolved = true;
          expect(value, same(playback.currentItem));
          return Uri.parse('http://127.0.0.1/episode');
        };
        expect(resolved, isFalse);
        sourceReady.complete();
        expect(await pending, Uri.parse('http://127.0.0.1/episode'));
        expect(resolved, isTrue);
      },
    );

    test('keeps an already installed resolver', () async {
      Future<Uri> existing(VideoItem _) async =>
          Uri.parse('http://127.0.0.1/ready');
      PodcastPlaybackHooks.resolve = existing;
      PodcastPlaybackHooks.deferResolveUntil(Completer<void>().future);
      expect(PodcastPlaybackHooks.resolve, same(existing));
      expect(
        await PodcastPlaybackHooks.resolve!(item()),
        Uri.parse('http://127.0.0.1/ready'),
      );
    });

    test(
      'failed initialization cannot recurse into the deferred resolver',
      () async {
        PodcastPlaybackHooks.deferResolveUntil(Future<void>.value());
        await expectLater(
          PodcastPlaybackHooks.resolve!(item()),
          throwsStateError,
        );
        expect(playback.controller, isNull);
      },
    );
  });
}

class _DelayedProgress extends ProgressTracker {
  _DelayedProgress(this.pending);
  final Future<PlaybackStateSnapshot?> pending;

  @override
  Future<PlaybackStateSnapshot?> restorePlaybackState() => pending;
}
