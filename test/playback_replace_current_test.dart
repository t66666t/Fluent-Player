import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playback_browse_history.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

import 'test_dir_cleanup.dart';

VideoItem _watchCard(String id, String bvid) => VideoItem(
  id: id,
  path: 'bilibili://stream/$bvid?cid=1',
  title: id,
  durationMs: 600000,
  lastUpdated: DateTime.now()
      .subtract(const Duration(minutes: 10))
      .millisecondsSinceEpoch,
  sourceFingerprint: 'bilibili-stream-card:$id',
  isBilibiliExported: true,
  isTransient: true,
  sourceRef: MediaSourceRef(
    value: bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: bvid,
    cid: 1,
    page: 1,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final navigation = PlaybackNavigationService.instance;

  setUp(() {
    navigation.resetNavigationQueueForTesting();
    PlaybackNavigationService.entryRouteOverrideForTesting = (item) =>
        MaterialPageRoute<void>(
          settings: PlaybackNavigationService.landscapeRouteSettings(item),
          builder: (_) => Scaffold(body: Text('player ${item.id}')),
        );
  });

  tearDown(() {
    PlaybackNavigationService.entryRouteOverrideForTesting = null;
  });

  List<Object?> playbackPages() => [
    for (final route in navigation.observer.routes)
      if (PlaybackNavigationService.isPlaybackRouteName(route.settings.name))
        route.settings.arguments,
  ];

  List<String?> stackNames() => [
    for (final route in navigation.observer.routes) route.settings.name,
  ];

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        navigatorObservers: [navigation.observer],
        home: const Scaffold(body: Text('home')),
      ),
    );
  }

  Future<void> clearStack(WidgetTester tester) async {
    AppToast.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
  }

  // The navigation queue was created outside the test's fake clock, so the
  // replacement runs on the real event loop.
  Future<void> replace(WidgetTester tester, VideoItem item) async {
    await tester.runAsync(() => navigation.replaceCurrentPlayback(item));
  }

  void push(Route<void> route) {
    AppToast.navigatorKey.currentState!.push(route);
  }

  testWidgets('browser back restores progress, paused state and the original '
      'queue while keeping just one player', (tester) async {
    final a = _watchCard('origin', 'BV1aa411c7mA');
    final b = _watchCard('linked', 'BV1bb411c7mB');
    final playback = _BrowsePlayback(b);
    final playlist = PlaylistManager()..setPlaylist([b]);
    final queueOwner = Object();
    final origin = PlaybackBrowseEntry(
      item: a,
      position: const Duration(seconds: 37),
      wasPlaying: false,
      queue: [a, b],
      queueOwner: queueOwner,
    );
    await pumpApp(tester);
    push(PlaybackNavigationService.buildPlaybackEntryRoute(a));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => navigation.replaceCurrentPlayback(b, browseOrigin: origin),
    );
    await tester.pumpAndSettle();
    expect(playbackPages(), ['linked']);
    expect(navigation.browseHistory.itemIds, {'origin'});
    late bool handled;
    await tester.runAsync(() async {
      handled = await navigation.returnToBrowseOrigin(playback, playlist);
    });
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(playbackPages(), ['origin']);
    expect(playback.currentItem, same(a));
    expect(playback.position, const Duration(seconds: 37));
    expect(playback.desiredPlaying, isFalse);
    expect(playlist.playlist.map((item) => item.id), ['origin', 'linked']);
    expect(playlist.queueOwner, same(queueOwner));
    expect(navigation.browseHistory.itemIds, isEmpty);
    await clearStack(tester);
    playback.dispose();
    playlist.dispose();
  });

  testWidgets('a nested landscape route leaves browser history for portrait', (
    tester,
  ) async {
    final a = _watchCard('origin', 'BV1aa411c7mA');
    final b = _watchCard('linked', 'BV1bb411c7mB');
    final playback = _BrowsePlayback(b);
    final playlist = PlaylistManager()..setPlaylist([b]);
    await pumpApp(tester);
    push(
      MaterialPageRoute<void>(
        settings: PlaybackNavigationService.portraitRouteSettings(b),
        builder: (_) => const Scaffold(body: Text('portrait')),
      ),
    );
    await tester.pumpAndSettle();
    push(PlaybackNavigationService.buildPlaybackEntryRoute(b));
    await tester.pumpAndSettle();
    navigation.browseHistory.record(
      origin: PlaybackBrowseEntry(
        item: a,
        position: Duration.zero,
        wasPlaying: true,
        queue: [a],
      ),
      target: b,
    );
    expect(await navigation.returnToBrowseOrigin(playback, playlist), isFalse);
    expect(navigation.browseHistory.itemIds, {'origin'});
    AppToast.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(navigation.browseHistory.itemIds, {'origin'});
    await clearStack(tester);
    expect(navigation.browseHistory.itemIds, isEmpty);
    playback.dispose();
    playlist.dispose();
  });

  testWidgets('a failed navigation does not poison subsequent requests', (
    tester,
  ) async {
    await pumpApp(tester);
    PlaybackNavigationService.entryRouteOverrideForTesting = (_) =>
        throw StateError('route failed');
    await tester.runAsync(() async {
      await expectLater(
        navigation.replaceCurrentPlayback(_watchCard('bad', 'BV1aa411c7mA')),
        throwsStateError,
      );
    });
    PlaybackNavigationService.entryRouteOverrideForTesting = (item) =>
        MaterialPageRoute<void>(
          settings: PlaybackNavigationService.landscapeRouteSettings(item),
          builder: (_) => Scaffold(body: Text('player ${item.id}')),
        );
    await replace(tester, _watchCard('good', 'BV1bb411c7mB'));
    await tester.pumpAndSettle();
    expect(playbackPages(), ['good']);
    await clearStack(tester);
  });

  testWidgets('the player on top is replaced, never stacked', (tester) async {
    await pumpApp(tester);
    push(
      PlaybackNavigationService.buildPlaybackEntryRoute(
        _watchCard('old', 'BV1aa411c7mA'),
      ),
    );
    await tester.pumpAndSettle();
    expect(navigation.hasPlaybackPage, isTrue);

    await replace(tester, _watchCard('new', 'BV1bb411c7mB'));
    await tester.pumpAndSettle();

    expect(playbackPages(), ['new']);
    expect(stackNames().length, 2);
    expect(find.text('player new'), findsOneWidget);
    await clearStack(tester);
  });

  testWidgets('a page opened above the player (uploader page) keeps one '
      'player on the stack', (tester) async {
    await pumpApp(tester);
    push(
      PlaybackNavigationService.buildPlaybackEntryRoute(
        _watchCard('old', 'BV1aa411c7mA'),
      ),
    );
    await tester.pumpAndSettle();
    push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/uploader'),
        builder: (_) => const Scaffold(body: Text('uploader')),
      ),
    );
    await tester.pumpAndSettle();

    await replace(tester, _watchCard('new', 'BV1bb411c7mB'));
    await tester.pumpAndSettle();

    expect(playbackPages(), ['new']);
    // Back from the new player goes to the uploader page, then home.
    expect(stackNames().last, PlaybackNavigationService.landscapeRouteName);
    expect(stackNames()[stackNames().length - 2], '/uploader');
    await clearStack(tester);
    expect(navigation.hasPlaybackPage, isFalse);
  });

  testWidgets('the same video on top is left alone', (tester) async {
    await pumpApp(tester);
    final card = _watchCard('same', 'BV1aa411c7mA');
    push(PlaybackNavigationService.buildPlaybackEntryRoute(card));
    await tester.pumpAndSettle();
    final before = navigation.observer.topRoute;

    await replace(tester, card);
    await tester.pumpAndSettle();

    expect(identical(navigation.observer.topRoute, before), isTrue);
    expect(playbackPages(), ['same']);
    await clearStack(tester);
  });

  group('the left watch-only card', () {
    late Directory root;
    late PathProviderPlatform originalPathProvider;
    late LibraryService library;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      root = await Directory.systemTemp.createTemp('playback_replace_');
      originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TempPathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      library = LibraryService()..resetLibraryForTesting();
      await library.init();
    });

    tearDown(() async {
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      SettingsService().largeDataRootPath = null;
      PathProviderPlatform.instance = originalPathProvider;
      await deleteTestTempDir(root);
    });

    testWidgets('is removed once its page was replaced', (tester) async {
      final oldCard = _watchCard('old-card', 'BV1aa411c7mA');
      final newCard = _watchCard('new-card', 'BV1bb411c7mB');
      await tester.runAsync(() async {
        await library.addTransientVideo(oldCard);
        await library.addTransientVideo(newCard);
      });
      await pumpApp(tester);
      push(PlaybackNavigationService.buildPlaybackEntryRoute(oldCard));
      await tester.pumpAndSettle();

      await replace(tester, newCard);
      await tester.pumpAndSettle();
      expect(playbackPages(), ['new-card']);

      // The app's clean-up treats what playback pages show as in use.
      final janitor = BilibiliTransientCardJanitor(
        library: library,
        inUseIds: () => playbackPages().whereType<String>().toSet(),
        grace: Duration.zero,
      );
      addTearDown(janitor.dispose);
      late int removed;
      await tester.runAsync(() async {
        removed = await janitor.sweep();
      });
      expect(removed, 1);
      expect(library.getVideo(oldCard.id), isNull);
      expect(library.getVideo(newCard.id), same(newCard));
      await clearStack(tester);
    });
  });
}

class _BrowsePlayback extends MediaPlaybackService {
  _BrowsePlayback(this.media) : super.forTesting();

  VideoItem media;
  Duration resumePosition = Duration.zero;
  bool playing = true;

  @override
  VideoItem get currentItem => media;
  @override
  Duration get position => resumePosition;
  @override
  bool get desiredPlaying => playing;
  @override
  void setPlaybackPageVisible(Object owner, bool visible) {}
  @override
  bool hasPlaybackPageOwnerOtherThan(Object owner) => true;

  @override
  Future<void> play(
    VideoItem item, {
    Duration? startPosition,
    bool autoPlay = true,
    bool forceRecreate = false,
    bool userInitiatedWatch = true,
    bool keepBookmarkOnFailure = false,
    String? cloudDriveQualityId,
    int? bilibiliQualityId,
    bool allowCloudDriveFallback = true,
    int? directEpoch,
  }) async {
    media = item;
    resumePosition = startPosition ?? Duration.zero;
    playing = autoPlay;
  }
}

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationCachePath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
