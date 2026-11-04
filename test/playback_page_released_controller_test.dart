import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/services/video_compose_manager.dart';
import 'package:video_player_app/widgets/video_compose_panel.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/screens/simple_video_player_screen.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'support/compose_queue_fakes.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';
import 'package:video_player_app/widgets/player_subtitle_sidebar_toggle.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/ambient_letterbox_layer.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';
import 'package:video_player_app/widgets/settings_panel.dart';
import 'package:video_player_app/widgets/subtitle_settings_sheet.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'test_dir_cleanup.dart';
import 'baidu_auto_subtitle_test.dart' show cloudItem, memoryStore;
import 'cloud_drive_playback_workflow_test.dart'
    show CloudPlaybackFake, CloudOfficialSubtitleFake;

/// Player stand-in. Building the view of a player that was already
/// disposed throws, so drawing a released player shows up as a test error.
/// Every view request is recorded.
class _StrictVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> positions = <int, Duration>{};
  int _nextPlayerId = 1;

  final List<int> buildViewCalls = <int>[];
  final List<int> playCalls = <int>[];
  int creationRequests = 0;
  bool reportDecodedFrameOnPlay = false;
  final Map<int, Stopwatch> decodedClocks = {};
  Completer<void>? creationGate;
  Completer<void>? pauseGate;
  Completer<void>? disposalGate;

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creationRequests++;
    await creationGate?.future;
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

  void failPlayer(int playerId) {
    _events[playerId]!.addError(
      PlatformException(
        code: 'test_decoder_failure',
        message: 'fixture decoder failed',
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    if (disposalGate != null) await disposalGate!.future;
    positions.remove(playerId);
    decodedClocks.remove(playerId)?.stop();
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
    if (reportDecodedFrameOnPlay) {
      (decodedClocks[playerId] ??= Stopwatch()).start();
    }
  }

  @override
  Future<void> pause(int playerId) async {
    await pauseGate?.future;
    decodedClocks[playerId]?.stop();
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    if (positions.containsKey(playerId)) positions[playerId] = position;
    decodedClocks[playerId]?.reset();
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async =>
      (positions[playerId] ?? Duration.zero) +
      (decodedClocks[playerId]?.elapsed ?? Duration.zero);

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) {
    buildViewCalls.add(playerId);
    if (!_events.containsKey(playerId)) {
      throw StateError('player $playerId was disposed');
    }
    return ColoredBox(
      key: ValueKey('fake-video-view-$playerId'),
      color: const Color(0xFF000000),
    );
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

class _OfflineUploaderApi extends BilibiliPublicApiService {
  @override
  Future<Map<String, dynamic>> getPublicJson(
    String path, {
    Map<String, dynamic> query = const <String, dynamic>{},
    required String referer,
    required String what,
    String? origin,
    bool signed = false,
    int attempt = 1,
  }) async => throw const BilibiliPublicApiException(
    'offline fixture',
    isNetworkError: true,
  );
}

// Page/controller tests use a fake clock. Desktop file writes started while
// closing a page must not leave the next test waiting on the shared disk queue.
class _MemoryPlaybackStateStore extends PlaybackStateStore {
  Map<String, dynamic>? snapshot;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    snapshot = Map<String, dynamic>.from(value);
  }

  @override
  Future<Map<String, dynamic>?> read() async => snapshot;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final _defaultValueTypeCheck = Provider.debugCheckInvalidValueType;

void main() {
  late Directory root;
  late PathProviderPlatform originalPaths;
  late VideoPlayerPlatform originalPlatform;
  late _StrictVideoPlatform platform;
  late LibraryService library;
  late PlaylistManager playlist;
  late MediaPlaybackService playback;
  late List<VideoItem> items;
  final settings = SettingsService();
  late bool originalAutoPlayOnCompletion;
  late bool originalWrap;

  setUp(() async {
    Provider.debugCheckInvalidValueType = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings.resetForTest();
    await settings.init();
    originalAutoPlayOnCompletion = settings.autoPlayOnCompletion;
    originalWrap = settings.playlistWrapToFirst;
    settings.autoPlayOnCompletion = false;
    settings.playlistWrapToFirst = false;
    root = await Directory.systemTemp.createTemp('released_controller_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    originalPlatform = VideoPlayerPlatform.instance;
    platform = _StrictVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    library = LibraryService()..resetLibraryForTesting();
    playlist = PlaylistManager();
    playback = MediaPlaybackService();
    await playback.stop();
    await playback.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(
        playbackStateStore: _MemoryPlaybackStateStore(),
      ),
    );
    await playback.sleepTimer.cancel();
    items = <VideoItem>[
      for (var i = 0; i < 2; i++)
        VideoItem(
          id: 'released-controller-$i',
          path: '${root.path}${Platform.pathSeparator}$i.mp4',
          title: 'Item $i',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
    ];
    for (final item in items) {
      await File(item.path).writeAsBytes(<int>[0]);
    }
    playlist.setPlaylist(items);
  });

  tearDown(() async {
    await playback.sleepTimer.cancel();
    await playback.stop();
    settings
      ..autoPlayOnCompletion = originalAutoPlayOnCompletion
      ..playlistWrapToFirst = originalWrap
      ..resetForTest();
    library.resetLibraryForTesting();
    VideoPlayerPlatform.instance = originalPlatform;
    PathProviderPlatform.instance = originalPaths;
    Provider.debugCheckInvalidValueType = _defaultValueTypeCheck;
    await deleteTestTempDir(root);
  });

  Widget host(
    Widget page, {
    bool reactivePlayback = false,
    bool observeRoutes = false,
    bool? disableAnimations,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<TranscriptionManager>.value(
          value: TranscriptionManager(),
        ),
        ChangeNotifierProvider<EmbeddedSubtitleService>.value(
          value: EmbeddedSubtitleService(),
        ),
        ChangeNotifierProvider<OcrSubtitleManager>.value(
          value: OcrSubtitleManager(library: library),
        ),
        ChangeNotifierProvider<VideoComposeManager>(
          create: (_) => VideoComposeManager(taskStore: MemoryComposeStore()),
        ),
        ChangeNotifierProvider<MediaMaterializationService>(
          create: (_) => MediaMaterializationService(BilibiliApiService()),
        ),
        ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        if (reactivePlayback)
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback)
        else
          Provider<MediaPlaybackService>.value(value: playback),
      ],
      child: MaterialApp(
        builder: disableAnimations == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: disableAnimations),
                child: child!,
              ),
        home: page,
        navigatorObservers: observeRoutes ? [AppToast.routeObserver] : [],
      ),
    );
  }

  void window(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester tester) async {
    for (var i = 0; i < 100 && playback.hasPendingPreviewForTest; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(playback.hasPendingPreviewForTest, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  /// Starts [item] on player [playerId] through the service, as the mini
  /// player or a previous page would have.
  Future<void> startPlayback(
    WidgetTester tester,
    VideoItem item,
    int playerId,
  ) async {
    await tester.runAsync(() async {
      final play = playback.play(item);
      await _until(() => platform.playerIds.contains(playerId));
      platform.initializePlayer(playerId);
      await play;
      await _until(() => playback.state == PlaybackState.playing);
    });
  }

  /// Plays a moment of the current item, then reports its end.
  Future<void> finishCurrent(WidgetTester tester, int playerId) async {
    await tester.runAsync(() async {
      final controller = playback.controller!;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 1),
        duration: const Duration(minutes: 1),
        isPlaying: true,
      );
      playback.updatePlaybackStateFromController(
        expectedItemId: playback.currentItem!.id,
        expectedController: controller,
      );
      platform.positions[playerId] = const Duration(minutes: 1);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 1),
        isPlaying: false,
      );
    });
  }

  /// Anything that rebuilds the page: a window resize, a rotation.
  Future<void> rebuildPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await settle(tester);
  }

  void expectNoErrorScreen(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
  }

  Future<void> waitForPreview(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done(), isTrue);
  }

  List<Object?> recordHaptics() {
    final calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return calls;
  }

  const hapticTick = 'HapticFeedbackType.selectionClick';
  const hapticLight = 'HapticFeedbackType.lightImpact';
  const hapticMedium = 'HapticFeedbackType.mediumImpact';

  for (final kind in ['portrait', 'landscape', 'mini', 'music']) {
    testWidgets(
      'haptics: $kind progress taps, drags, cancellation and live switch',
      (tester) async {
        window(
          tester,
          kind == 'landscape' ? const Size(1280, 720) : const Size(430, 932),
        );
        await startPlayback(tester, items.first, 1);
        final calls = recordHaptics();
        final Widget page = switch (kind) {
          'portrait' => PortraitVideoScreen(videoItem: items.first),
          'landscape' => VideoPlayerScreen(videoItem: items.first),
          'mini' => const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(isVisible: true),
            ),
          ),
          _ => Scaffold(
            body: Center(
              child: MusicPlaybackControls(
                totalDuration: const Duration(minutes: 1),
                progress: 0.2,
                onProgressChangeStart: (_) {},
                onProgressChanged: (_) {},
                onProgressChangeEnd: (value) => playback.seekTo(
                  Duration(milliseconds: (value * 60000).round()),
                ),
              ),
            ),
          ),
        };
        await tester.pumpWidget(host(page, reactivePlayback: true));
        await settle(tester);
        if (kind == 'landscape') {
          await tester.tap(
            find.byKey(const ValueKey('landscape-player-surface')),
          );
          await settle(tester);
        }
        expect(calls, isEmpty, reason: 'Restoring playback is silent');
        final slider = switch (kind) {
          'portrait' => find.byKey(const ValueKey('portrait-progress')),
          'landscape' => find.descendant(
            of: find.byKey(
              const ValueKey('video-controls-progress-hover-region'),
            ),
            matching: find.byType(Slider),
          ),
          'mini' => find.descendant(
            of: find.byType(MiniPlaybackCard),
            matching: find.byType(Slider),
          ),
          _ => find.byKey(const ValueKey('music-progress-slider')),
        };
        final rect = tester.getRect(slider);
        await tester.tapAt(rect.center);
        await tester.pump();
        expect(calls, [hapticTick]);

        calls.clear();
        final drag = await tester.startGesture(rect.center);
        await drag.moveBy(const Offset(40, 0));
        await tester.pump();
        await drag.moveBy(const Offset(20, 0));
        await tester.pump();
        await drag.up();
        await tester.pump();
        expect(calls.first, hapticTick);
        expect(calls.last, hapticLight);

        if (kind != 'music') {
          calls.clear();
          final cancelRect = tester.getRect(slider);
          final cancelled = await tester.startGesture(cancelRect.center);
          await cancelled.moveBy(const Offset(25, 0));
          await tester.pump();
          final cancelY = kind == 'mini'
              ? tester.getRect(find.byType(MiniPlaybackCard)).top - 40
              : 10.0;
          await cancelled.moveTo(Offset(cancelRect.center.dx + 25, cancelY));
          await tester.pump();
          await cancelled.moveTo(Offset(cancelRect.center.dx + 30, cancelY));
          await tester.pump();
          final feedbackBeforeRelease = List<Object?>.of(calls);
          await cancelled.up();
          await tester.pump();
          expect(calls.where((c) => c == hapticMedium), hasLength(1));
          expect(
            calls,
            feedbackBeforeRelease,
            reason: 'Cancelling adds no commit pulse after movement feedback',
          );
        }

        calls.clear();
        final muted = await tester.startGesture(rect.center);
        await tester.pump();
        await settings.saveEnableHapticFeedback(false);
        calls.clear();
        await muted.moveBy(const Offset(60, 0));
        await muted.up();
        await tester.pump();
        expect(calls, isEmpty);
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.stop());
        await close(tester);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'portrait keyboard progress commits horizontal drags and cancels upward drags',
    (tester) async {
      const screenSize = Size(430, 932);
      window(tester, screenSize);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(
          PortraitVideoScreen(videoItem: items.first),
          reactivePlayback: true,
        ),
      );
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 500);
      tester.view.padding = const FakeViewPadding(top: 24);
      await settle(tester);

      final slider = find.byKey(const ValueKey('portrait-progress'));
      final center = tester.getCenter(slider);
      expect(
        center.dy,
        lessThan(screenSize.height * .25),
        reason: 'The compact progress bar enters the former cancellation area',
      );
      expect(tester.widget<Slider>(slider).onChangeEnd, isNotNull);
      final originalPosition = platform.positions[1]!;
      final horizontal = await tester.startGesture(center);
      await horizontal.moveBy(const Offset(40, 0));
      await tester.pump();
      await horizontal.moveBy(const Offset(20, 0));
      await tester.pump();
      await horizontal.up();
      await tester.pump();
      await tester.runAsync(
        () => _until(() => platform.positions[1] != originalPosition),
      );
      await tester.pump();
      expect(platform.positions[1], greaterThan(originalPosition));
      expectNoErrorScreen(tester);

      final committedPosition = platform.positions[1]!;
      final progressBox = tester.renderObject<RenderBox>(slider);
      // Express the cancellation movement relative to the real, scaled bar.
      final cancelPoint = progressBox.localToGlobal(
        Offset(progressBox.size.width / 2, -72),
      );
      final upward = await tester.startGesture(tester.getCenter(slider));
      await upward.moveBy(const Offset(-25, 0));
      await tester.pump();
      await upward.moveTo(cancelPoint);
      await tester.pump();
      await upward.moveBy(const Offset(5, 0));
      await tester.pump();
      await upward.up();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(platform.positions[1], committedPosition);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final left in [false, true]) {
    testWidgets(
      'haptics: subtitle and AI resize and navigation, left=$left',
      (tester) async {
        window(tester, const Size(1280, 720));
        settings.isLeftHandedMode = left;
        await startPlayback(tester, items.first, 1);
        final calls = recordHaptics();
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: items.first)),
        );
        await settle(tester);
        expect(calls, isEmpty);
        final toggle = find.byKey(
          const ValueKey('player-subtitle-sidebar-toggle'),
        );
        await tester.tap(toggle);
        await settle(tester);
        expect(calls, [hapticLight]);
        calls.clear();
        await tester.tap(toggle);
        await settle(tester);
        expect(calls, [hapticMedium]);

        final resize = find.byKey(
          const ValueKey('player-sidebar-resize-handle'),
        );
        final beforeSubtitle = settings.userSubtitleSidebarWidth;
        calls.clear();
        await tester.drag(resize, Offset(left ? 60 : -60, 0));
        await settle(tester);
        expect(calls.first, hapticTick);
        expect(calls.last, hapticLight);
        expect(settings.userSubtitleSidebarWidth, greaterThan(beforeSubtitle));
        final subtitleWidth = settings.userSubtitleSidebarWidth;

        calls.clear();
        tester
            .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
            .onOpenAiChat!();
        await settle(tester);
        expect(calls, [hapticLight]);
        final beforeAi = settings.userAiSidebarWidth;
        calls.clear();
        await tester.drag(resize, Offset(left ? 60 : -60, 0));
        await settle(tester);
        expect(calls.first, hapticTick);
        expect(calls.last, hapticLight);
        expect(settings.userAiSidebarWidth, greaterThan(beforeAi));
        expect(settings.userSubtitleSidebarWidth, subtitleWidth);

        calls.clear();
        final cancelled = await tester.startGesture(tester.getCenter(resize));
        await cancelled.moveBy(Offset(left ? 40 : -40, 0));
        await tester.pump();
        final feedbackBeforeCancel = List<Object?>.of(calls);
        await cancelled.cancel();
        await settle(tester);
        expect(
          calls,
          feedbackBeforeCancel,
          reason: 'Pointer cancellation adds no commit pulse',
        );
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.stop());
        await close(tester);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'haptics: portrait tool navigation and fullscreen emit once',
    (tester) async {
      window(tester, const Size(720, 1280));
      await startPlayback(tester, items.first, 1);
      final calls = recordHaptics();
      await tester.pumpWidget(
        host(PortraitVideoScreen(videoItem: items.first)),
      );
      await settle(tester);
      expect(calls, isEmpty);
      final compose = tester
          .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
          .onOpenVideoCompose!;
      compose();
      await tester.pump();
      expect(calls, [hapticLight]);
      await settle(tester);
      expect(calls, [
        hapticLight,
      ], reason: 'Preparing subtitles does not add a second pulse');
      compose();
      await settle(tester);
      calls.clear();
      tester
          .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
          .onOpenSettings!();
      await settle(tester);
      expect(calls, [hapticLight]);
      calls.clear();
      tester
          .widget<SettingsPanel>(find.byType(SettingsPanel))
          .onOpenSubtitleSettings!();
      await settle(tester);
      expect(calls, [hapticLight]);
      calls.clear();
      tester
          .widget<SubtitleSettingsSheet>(find.byType(SubtitleSettingsSheet))
          .onClose();
      await settle(tester);
      expect(calls, [hapticLight]);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('portrait-fullscreen')));
      await settle(tester);
      expect(calls, [hapticLight]);
      expect(find.byType(VideoPlayerScreen), findsOneWidget);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final portrait in [false, true]) {
    for (final enabled in [false, true]) {
      for (final uploader in [false, true]) {
        testWidgets(
          'covered ${portrait ? 'portrait' : 'landscape'} player honors '
          'autoPause=$enabled on ${uploader ? 'UP profile' : 'ordinary page'}',
          (tester) async {
            window(
              tester,
              portrait ? const Size(720, 1280) : const Size(1280, 720),
            );
            settings.autoPauseOnExit = enabled;
            await startPlayback(tester, items.first, 1);
            final original = playback.controller!;
            await tester.pumpWidget(
              host(
                portrait
                    ? PortraitVideoScreen(videoItem: items.first)
                    : VideoPlayerScreen(
                        videoItem: items.first,
                        skipAutoPauseOnExit: true,
                      ),
                observeRoutes: true,
              ),
            );
            await settle(tester);
            final context = tester.element(find.byType(VideoControlsOverlay));
            final navigator = Navigator.of(context);
            if (uploader) {
              unawaited(
                openBilibiliUploader(
                  context,
                  mid: 9527,
                  api: _OfflineUploaderApi(),
                ),
              );
            } else {
              unawaited(
                navigator.push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('browse page')),
                  ),
                ),
              );
            }
            await settle(tester);
            expect(playback.isTransportPlaying, !enabled);
            expect(original.value.isPlaying, !enabled);
            expect(playback.controller, same(original));
            expect(playback.hasVisiblePlaybackPageForTest, isFalse);
            if (uploader) {
              expect(find.byType(BilibiliUploaderScreen), findsOneWidget);
            }
            navigator.pop();
            await settle(tester);
            expect(
              playback.isTransportPlaying,
              !enabled,
              reason: 'return does not restart paused audio',
            );
            expect(playback.controller, same(original));
            expectNoErrorScreen(tester);
            await tester.runAsync(() => playback.pause());
            await close(tester);
          },
        );
      }
    }

    testWidgets(
      'popups and playback handoffs keep ${portrait ? 'portrait' : 'landscape'} playing',
      (tester) async {
        window(
          tester,
          portrait ? const Size(720, 1280) : const Size(1280, 720),
        );
        settings.autoPauseOnExit = true;
        await startPlayback(tester, items.first, 1);
        await tester.pumpWidget(
          host(
            portrait
                ? PortraitVideoScreen(videoItem: items.first)
                : VideoPlayerScreen(videoItem: items.first),
            observeRoutes: true,
          ),
        );
        await settle(tester);
        final context = tester.element(find.byType(VideoControlsOverlay));
        final navigator = Navigator.of(context);
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(title: Text('popup')),
          ),
        );
        await settle(tester);
        expect(playback.isTransportPlaying, isTrue);
        expect(playback.hasVisiblePlaybackPageForTest, isTrue);
        navigator.pop();
        await settle(tester);
        unawaited(
          navigator.push(
            PlaybackPageRoute<void>(
              settings: const RouteSettings(name: 'music-player'),
              builder: (_) => const Scaffold(body: Text('playback handoff')),
            ),
          ),
        );
        await settle(tester);
        expect(playback.isTransportPlaying, isTrue);
        navigator.pop();
        await settle(tester);
        expect(playback.isTransportPlaying, isTrue);
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.pause());
        await close(tester);
      },
    );
  }

  for (final portrait in [false, true]) {
    for (final throughQueue in [false, true]) {
      for (final wasPlaying in [false, true]) {
        testWidgets(
          'compose preview returns a mounted ${portrait ? 'portrait' : 'landscape'} '
          'video through ${throughQueue ? 'queue' : 'page'} with '
          '${wasPlaying ? 'playing' : 'paused'} source',
          (tester) async {
            settings.autoPauseOnExit = true;
            window(
              tester,
              portrait ? const Size(720, 1280) : const Size(1280, 720),
            );
            await startPlayback(tester, items.first, 1);
            await tester.runAsync(() async {
              await playback.seekTo(const Duration(seconds: 13));
              if (!wasPlaying) await playback.pause();
            });
            final original = playback.controller!;
            final sourcePosition = playback.position;
            final page = portrait
                ? PortraitVideoScreen(videoItem: items.first)
                : VideoPlayerScreen(videoItem: items.first);
            await tester.pumpWidget(host(page, observeRoutes: true));
            await settle(tester);
            final navigator = tester.state<NavigatorState>(
              find.byType(Navigator).first,
            );
            if (throughQueue) {
              unawaited(
                showDialog<void>(
                  context: tester.element(find.byType(Scaffold).first),
                  builder: (_) => const AlertDialog(title: Text('合成队列测试')),
                ),
              );
              await settle(tester);
            }
            final route = AppMaterialPageRoute<void>(
              settings: const RouteSettings(name: '/compose/preview'),
              allowSnapshotting: false,
              builder: (_) => SimpleVideoPlayerScreen(
                videoPath: items[1].path,
                title: '成片',
              ),
            );
            unawaited(navigator.push(route));
            await tester.pump();
            await waitForPreview(tester, () => platform.playerIds.contains(2));
            platform.initializePlayer(2);
            await waitForPreview(tester, () => platform.playCalls.contains(2));
            await settle(tester);
            expect(playback.isPlaying, isFalse);
            expect(
              find.byKey(const ValueKey('fake-video-view-2')),
              findsOneWidget,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle(tester);
            await waitForPreview(
              tester,
              () =>
                  !platform.playerIds.contains(2) &&
                  playback.isPlaying == wasPlaying,
            );
            if (throughQueue) {
              expect(find.text('合成队列测试'), findsOneWidget);
              navigator.pop();
              await settle(tester);
            }
            await settle(tester);
            expect(playback.currentItem?.id, items.first.id);
            expect(playback.controller, same(original));
            expect(playback.position, sourcePosition);
            expect(playback.isPlaying, wasPlaying);
            expect(platform.playerIds, [1]);
            expect(
              find.byKey(const ValueKey('fake-video-view-1')),
              findsOneWidget,
            );
            expectNoErrorScreen(tester);
            await tester.runAsync(() => playback.pause());
            await close(tester);
          },
        );
      }
    }
  }

  for (final pendingCreation in [false, true]) {
    testWidgets(
      'compose preview exits during ${pendingCreation ? 'native create' : 'initialization'} '
      'without late playback or blocking source restoration',
      (tester) async {
        window(tester, const Size(1280, 720));
        await startPlayback(tester, items.first, 1);
        final original = playback.controller;
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
        );
        await settle(tester);
        final gate = pendingCreation
            ? (platform.creationGate = Completer<void>())
            : null;
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        final route = AppMaterialPageRoute<void>(
          settings: const RouteSettings(name: '/compose/preview'),
          builder: (_) =>
              SimpleVideoPlayerScreen(videoPath: items[1].path, title: '加载中成片'),
        );
        unawaited(navigator.push(route));
        await tester.pump();
        await waitForPreview(tester, () => platform.creationRequests == 2);
        await settle(tester);
        expect(playback.isPlaying, isFalse);
        await tester.binding.handlePopRoute();
        await settle(tester);
        await waitForPreview(tester, () => playback.isPlaying);
        expect(playback.isPlaying, isTrue);
        if (gate != null) {
          gate.complete();
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        await waitForPreview(tester, () => platform.playerIds.length == 1);
        expect(platform.playCalls, isNot(contains(2)));
        expect(platform.playerIds, [1]);
        expect(playback.controller, same(original));
        expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.pause());
        await close(tester);
      },
    );
  }

  testWidgets(
    'compose preview error still supports Escape and restores playback',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
      );
      await settle(tester);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push(
          AppMaterialPageRoute<void>(
            settings: const RouteSettings(name: '/compose/preview'),
            builder: (_) => SimpleVideoPlayerScreen(
              videoPath: '${root.path}/missing.mp4',
              title: 'missing',
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(find.text('媒体文件不存在，可能已被移动或删除'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(playback.isPlaying, isTrue);
      expect(platform.playerIds, [1]);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.pause());
      await close(tester);
    },
  );

  testWidgets(
    'compose preview can be opened repeatedly without replacing the source',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      final source = playback.controller;
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
      );
      await settle(tester);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      for (var visit = 0; visit < 3; visit++) {
        final id = visit + 2;
        unawaited(
          navigator.push(
            AppMaterialPageRoute<void>(
              settings: const RouteSettings(name: '/compose/preview'),
              allowSnapshotting: false,
              builder: (_) => SimpleVideoPlayerScreen(
                videoPath: items[1].path,
                title: '预览 $visit',
              ),
            ),
          ),
        );
        await tester.pump();
        await waitForPreview(tester, () => platform.playerIds.contains(id));
        platform.initializePlayer(id);
        await waitForPreview(tester, () => platform.playCalls.contains(id));
        await settle(tester);
        final overlay = tester.widget<VideoControlsOverlay>(
          find.byType(VideoControlsOverlay),
        );
        overlay.onBackPressed();
        await settle(tester);
        await waitForPreview(
          tester,
          () => !platform.playerIds.contains(id) && playback.isPlaying,
        );
        expect(playback.controller, same(source));
        expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
        expectNoErrorScreen(tester);
      }
      await tester.runAsync(() => playback.pause());
      await close(tester);
    },
  );

  testWidgets('compose preview return preserves an explicit source pause', (
    tester,
  ) async {
    window(tester, const Size(1280, 720));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(
      host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
    );
    await settle(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        AppMaterialPageRoute<void>(
          settings: const RouteSettings(name: '/compose/preview'),
          builder: (_) =>
              SimpleVideoPlayerScreen(videoPath: items[1].path, title: '预览'),
        ),
      ),
    );
    await tester.pump();
    await waitForPreview(tester, () => platform.playerIds.contains(2));
    platform.initializePlayer(2);
    await waitForPreview(tester, () => platform.playCalls.contains(2));
    await tester.runAsync(() => playback.pause());
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await waitForPreview(tester, () => !platform.playerIds.contains(2));
    expect(playback.desiredPlaying, isFalse);
    expect(playback.isPlaying, isFalse);
    expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
    expectNoErrorScreen(tester);
    await close(tester);
  });

  testWidgets(
    'compose preview exit joins a slow source pause without late player creation',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
      );
      await settle(tester);
      final gate = platform.pauseGate = Completer<void>();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push(
          AppMaterialPageRoute<void>(
            settings: const RouteSettings(name: '/compose/preview'),
            builder: (_) => SimpleVideoPlayerScreen(
              videoPath: items[1].path,
              title: '等待暂停',
            ),
          ),
        ),
      );
      await tester.pump();
      await waitForPreview(tester, () => !playback.isPlaying);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(SimpleVideoPlayerScreen), findsNothing);
      gate.complete();
      await waitForPreview(tester, () => playback.isPlaying);
      expect(platform.creationRequests, 1);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.pause());
      await close(tester);
    },
  );

  testWidgets(
    'compose preview waits for the preceding native disposal before suspending again',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: items.first), observeRoutes: true),
      );
      await settle(tester);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      final first = AppMaterialPageRoute<void>(
        settings: const RouteSettings(name: '/compose/preview'),
        builder: (_) =>
            SimpleVideoPlayerScreen(videoPath: items[1].path, title: '预览一'),
      );
      unawaited(navigator.push(first));
      await tester.pump();
      await waitForPreview(tester, () => platform.playerIds.contains(2));
      platform.initializePlayer(2);
      await waitForPreview(tester, () => platform.playCalls.contains(2));
      await settle(tester);
      final gate = platform.disposalGate = Completer<void>();
      tester
          .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
          .onBackPressed();
      await settle(tester);
      expect(playback.isPlaying, isFalse);
      unawaited(
        navigator.push(
          AppMaterialPageRoute<void>(
            settings: const RouteSettings(name: '/compose/preview'),
            builder: (_) =>
                SimpleVideoPlayerScreen(videoPath: items[1].path, title: '预览二'),
          ),
        ),
      );
      await settle(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(platform.creationRequests, 2);
      gate.complete();
      await waitForPreview(tester, () => platform.playerIds.contains(3));
      platform.initializePlayer(3);
      await waitForPreview(tester, () => platform.playCalls.contains(3));
      expect(playback.isPlaying, isFalse);
      expect(platform.playerIds, [1, 3]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await waitForPreview(
        tester,
        () => platform.playerIds.length == 1 && playback.isPlaying,
      );
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.pause());
      await close(tester);
    },
  );

  for (final replace in [false, true]) {
    testWidgets(
      'compose preview restoration preserves a ${replace ? 'replacement' : 'stopped'} session',
      (tester) async {
        await startPlayback(tester, items.first, 1);
        final suspension = await tester.runAsync(playback.suspendForPreview);
        await tester.runAsync(playback.stop);
        if (replace) {
          await startPlayback(tester, items[1], 2);
          await tester.runAsync(playback.pause);
        }
        final current = playback.controller;
        await tester.runAsync(suspension!.restore);
        expect(playback.controller, same(current));
        expect(playback.currentItem?.id, replace ? items[1].id : null);
        expect(playback.isPlaying, isFalse);
        expect(playback.hasPendingPreviewForTest, isFalse);
        await tester.runAsync(playback.stop);
        await close(tester);
      },
    );
  }

  testWidgets(
    'compose preview restores the original play intent when its source was still loading',
    (tester) async {
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = playback.play(items.first);
        await _until(() => platform.playerIds.contains(1));
      });
      final suspension = await tester.runAsync(playback.suspendForPreview);
      await tester.runAsync(() async {
        platform.initializePlayer(1);
        await pending;
      });
      expect(playback.isPlaying, isFalse);
      await tester.runAsync(suspension!.restore);
      expect(playback.isPlaying, isTrue);
      expect(playback.currentItem?.id, items.first.id);
      await tester.runAsync(playback.stop);
      await close(tester);
    },
  );

  testWidgets('landscape keeps its hidden chrome and geometry through a slow '
      'controller initialization', (tester) async {
    window(tester, const Size(1280, 720));
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = playback.play(items.first);
      await _until(() => platform.playerIds.contains(1));
    });
    await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
    await settle(tester);
    final overlay = find.byType(VideoControlsOverlay);
    final initialState = tester.state<VideoControlsOverlayState>(overlay);
    expect(initialState.controlsVisible, isFalse);
    expect(tester.widget<VideoControlsOverlay>(overlay).isPreparing, isTrue);
    final surface = tester.getRect(
      find.byKey(const ValueKey('landscape-player-surface')),
    );
    final top = tester.getRect(
      find.byKey(const ValueKey('video-controls-close')),
    );
    final bottom = tester.getRect(
      find.byKey(const ValueKey('video-controls-bottom-panel')),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(initialState.controlsVisible, isFalse);

    await tester.runAsync(() async {
      platform.initializePlayer(1);
      await pending;
    });
    await settle(tester);
    expect(
      tester.state<VideoControlsOverlayState>(overlay),
      same(initialState),
    );
    expect(tester.widget<VideoControlsOverlay>(overlay).isPreparing, isFalse);
    expect(initialState.controlsVisible, isFalse);
    expect(
      tester.getRect(find.byKey(const ValueKey('landscape-player-surface'))),
      surface,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('video-controls-close'))),
      top,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('video-controls-bottom-panel'))),
      bottom,
    );
    final hiddenPlay = find.byKey(const ValueKey('video-controls-play-pause'));
    expect(hiddenPlay.hitTestable(), findsNothing);
    await tester.tapAt(surface.center);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 250));
    expect(initialState.controlsVisible, isTrue);
    expect(hiddenPlay.hitTestable(), findsOneWidget);
    expectNoErrorScreen(tester);
    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  for (final left in [false, true]) {
    for (final size in [
      const Size(568, 320),
      const Size(844, 390),
      const Size(1280, 720),
      const Size(1920, 1080),
    ]) {
      testWidgets('subtitle edge toggle preserves gestures and state, '
          'left=$left, size=$size', (tester) async {
        window(tester, size);
        tester.view.viewPadding = FakeViewPadding(
          left: left ? 36 : 0,
          right: left ? 0 : 36,
        );
        settings.isLeftHandedMode = left;
        await startPlayback(tester, items.first, 1);
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: items.first)),
        );
        await settle(tester);
        final toggle = find.byKey(
          const ValueKey('player-subtitle-sidebar-toggle'),
        );
        final resize = find.byKey(
          const ValueKey('player-sidebar-resize-handle'),
        );
        final surface = find.byKey(const ValueKey('landscape-player-surface'));
        final originalSubtitle = tester.element(find.byType(SubtitleSidebar));
        final originalVideo = tester.element(
          find.byKey(const ValueKey('fake-video-view-1')),
        );
        final originalWidth = settings.userSubtitleSidebarWidth;
        final controls = tester.state<VideoControlsOverlayState>(
          find.byType(VideoControlsOverlay),
        );
        final buttonRect = tester.getRect(toggle);
        final resizeRect = tester.getRect(resize);
        expect(buttonRect.overlaps(tester.getRect(surface)), isTrue);
        expect(
          tester.getSize(surface).width,
          closeTo(size.width - originalWidth - 12, 0.001),
          reason: 'The floating entry must not reserve any video width.',
        );
        expect(buttonRect.overlaps(resizeRect), isFalse);
        expect(
          left
              ? buttonRect.left - resizeRect.right
              : resizeRect.left - buttonRect.right,
          closeTo(0, 0.001),
        );
        expect(controls.controlsVisible, isFalse);

        // A swipe begun on the button must never become a splitter gesture.
        await tester.drag(toggle, Offset(left ? 60 : -60, 0));
        await settle(tester);
        expect(settings.userSubtitleSidebarWidth, originalWidth);
        expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);

        // The splitter keeps its independent, enlarged gesture target.
        await tester.drag(resize, Offset(left ? 40 : -40, 0));
        await settle(tester);
        final resizedWidth = settings.userSubtitleSidebarWidth;
        expect(resizedWidth, greaterThan(originalWidth));

        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final intermediateWidth = tester.getSize(surface).width;
        expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
        // Reverse the same transition before its outgoing fade finishes.
        await tester.tap(toggle);
        await settle(tester);
        expect(tester.getSize(surface).width, lessThan(intermediateWidth));
        expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);
        expect(
          tester.element(find.byType(SubtitleSidebar)),
          same(originalSubtitle),
        );

        await tester.tap(toggle);
        await settle(tester);
        expect(find.byType(SubtitleSidebar), findsNothing);
        expect(toggle.hitTestable(), findsOneWidget);
        expect(tester.getSize(surface).width, size.width);
        final collapsedButton = tester.getRect(toggle);
        expect(
          left ? collapsedButton.left : size.width - collapsedButton.right,
          greaterThanOrEqualTo(36),
        );
        expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
        expect(controls.controlsVisible, isFalse);
        expect(settings.userSubtitleSidebarWidth, resizedWidth);

        // The existing toolbar/shortcut and the edge entry share one state.
        tester
            .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
            .onToggleSidebar!();
        await settle(tester);
        expect(
          tester.element(find.byType(SubtitleSidebar)),
          same(originalSubtitle),
        );
        expect(settings.userSubtitleSidebarWidth, resizedWidth);
        expect(
          tester.element(find.byKey(const ValueKey('fake-video-view-1'))),
          same(originalVideo),
        );
        expect(
          tester
              .widget<PlayerSubtitleSidebarToggle>(
                find.byType(PlayerSubtitleSidebarToggle),
              )
              .expanded,
          isTrue,
        );
        final unlockedSurface = tester.getRect(surface);
        tester
            .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
            .onToggleLock();
        await settle(tester);
        expect(toggle.hitTestable(), findsNothing);
        expect(tester.getRect(surface), unlockedSurface);
        tester
            .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
            .onToggleLock();
        await settle(tester);
        expect(toggle.hitTestable(), findsOneWidget);
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.stop());
        await close(tester);
      });
    }
  }

  for (final ghostEnabled in [false, true]) {
    testWidgets(
      'landscape ghost captions follow direct AI and subtitle navigation, '
      'enabled=$ghostEnabled',
      (tester) async {
        window(tester, const Size(1280, 720));
        settings.isLandscapeSubtitleSidebarVisible = false;
        settings.isGhostModeEnabled = ghostEnabled;
        await startPlayback(tester, items.first, 1);
        playback.setSubtitleState(
          paths: ['ghost.srt'],
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(minutes: 1),
              text: 'Ghost sidebar regression caption',
            ),
          ],
          secondary: const [],
        );
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: items.first)),
        );
        await settle(tester);

        VideoControlsOverlay controls() => tester.widget<VideoControlsOverlay>(
          find.byType(VideoControlsOverlay),
        );
        void expectCaptionMode(bool ghost) {
          final overlay = tester.widget<SubtitleOverlayGroup>(
            find.byType(SubtitleOverlayGroup),
          );
          expect(
            overlay.entries.single.text,
            'Ghost sidebar regression caption',
          );
          expect(overlay.isGhostMode, ghost);
        }

        try {
          expectCaptionMode(false);
          controls().onOpenAiChat!();
          await settle(tester);
          expect(find.byType(AiChatPanel), findsOneWidget);
          expectCaptionMode(ghostEnabled);
          expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);

          await tester.runAsync(
            () => settings.saveGhostModeEnabled(!ghostEnabled),
          );
          await settle(tester);
          expectCaptionMode(!ghostEnabled);
          await tester.runAsync(
            () => settings.saveGhostModeEnabled(ghostEnabled),
          );
          await settle(tester);

          tester.widget<AiChatPanel>(find.byType(AiChatPanel)).onClose!();
          await settle(tester);
          expect(find.byType(AiChatPanel), findsNothing);
          expectCaptionMode(false);
          expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);

          controls().onToggleSidebar!();
          await settle(tester);
          expectCaptionMode(ghostEnabled);
          tester
              .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
              .onOpenAiChat!();
          await settle(tester);
          expectCaptionMode(ghostEnabled);
          tester.widget<AiChatPanel>(find.byType(AiChatPanel)).onClose!();
          await settle(tester);
          expect(find.byType(SubtitleSidebar), findsOneWidget);
          expectCaptionMode(ghostEnabled);
          expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);
          expectNoErrorScreen(tester);
        } finally {
          await tester.runAsync(() => playback.stop());
          await close(tester);
        }
      },
    );
  }

  for (final left in [false, true]) {
    testWidgets(
      'landscape sidebar animation retains native surface and chrome, left=$left',
      (tester) async {
        window(tester, const Size(1280, 720));
        settings.isLeftHandedMode = left;
        items.first.chapters = const [
          MediaChapter(title: 'Intro', startMs: 0, endMs: 30000),
          MediaChapter(title: 'Next', startMs: 30000, endMs: 60000),
        ];
        await startPlayback(tester, items.first, 1);
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: items.first)),
        );
        await settle(tester);
        final texture = tester.element(find.byType(VideoPlayer));
        final controller = playback.controller;
        VideoControlsOverlay controls() => tester.widget<VideoControlsOverlay>(
          find.byType(VideoControlsOverlay),
        );
        final destinations = <VoidCallback>[
          controls().onOpenSettings!,
          controls().onOpenSubtitleManager!,
          controls().onOpenSubtitleEditor!,
          controls().onOpenVideoCompose!,
          controls().onOpenOcrSubtitle!,
          controls().onOpenChapters!,
          controls().onOpenAiChat!,
          controls().onToggleFloatingSubtitleSettings!,
        ];
        for (final open in destinations) {
          open();
          await tester.pump();
          await tester.pump();
          if (find.byType(VideoControlsOverlay).evaluate().isEmpty) {
            expect(find.byType(SubtitleSettingsSheet), findsOneWidget);
            continue;
          }
          final chrome = controls();
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(microseconds: 8333));
            expect(
              controls(),
              same(chrome),
              reason:
                  'Constraint-only animation must not rebuild the controls widget',
            );
            expect(tester.element(find.byType(VideoPlayer)), same(texture));
            expect(playback.controller, same(controller));
          }
        }
        destinations[3]();
        await tester.pump();
        expect(
          find.byType(VideoComposePanel),
          findsOneWidget,
          reason:
              'The compose shell opens before embedded subtitle preparation',
        );
        controls().onToggleSidebar!();
        await settle(tester);
        expect(find.byType(SubtitleSidebar), findsOneWidget);
        expect(playback.controller, same(controller));
        controls().onOpenSubtitleManager!();
        await tester.pump();
        tester
            .widget<SubtitleManagementSheet>(
              find.byType(SubtitleManagementSheet),
            )
            .onOpenAi();
        await tester.pump();
        expect(find.byType(AiTranscriptionPanel), findsOneWidget);
        expect(tester.element(find.byType(VideoPlayer)), same(texture));
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.stop());
        await close(tester);
      },
    );

    for (final reduced in [false, true]) {
      testWidgets(
        'landscape geometry survives reversals, resize and keyboard, left=$left reduced=$reduced',
        (tester) async {
          window(tester, const Size(1280, 720));
          settings.isLeftHandedMode = left;
          await startPlayback(tester, items.first, 1);
          await tester.pumpWidget(
            host(
              VideoPlayerScreen(videoItem: items.first),
              disableAnimations: reduced,
            ),
          );
          await settle(tester);
          final texture = tester.element(find.byType(VideoPlayer));
          final controller = playback.controller;
          final surface = find.byKey(
            const ValueKey('landscape-player-surface'),
          );
          VideoControlsOverlay controls() => tester
              .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay));
          DesktopPlayerSidebar dock() => tester.widget<DesktopPlayerSidebar>(
            find.byType(DesktopPlayerSidebar),
          );
          for (var tap = 0; tap < 40; tap++) {
            final before = tester.getRect(surface);
            controls().onToggleSidebar!();
            await tester.pump();
            if (reduced) {
              expect(dock().motion!.isAnimating, isFalse);
            } else {
              expect(
                tester.getRect(surface),
                before,
                reason: 'Reversing starts at the geometry currently on screen',
              );
            }
            await tester.pump(const Duration(microseconds: 8333));
            expect(tester.element(find.byType(VideoPlayer)), same(texture));
          }
          await settle(tester);
          final handle = find.byKey(
            const ValueKey('player-sidebar-resize-handle'),
          );
          final drag = await tester.startGesture(tester.getCenter(handle));
          final width = settings.userSubtitleSidebarWidth;
          await drag.moveBy(Offset(left ? 24 : -24, 0));
          await tester.pump();
          await drag.moveBy(Offset(left ? 40 : -40, 0));
          await tester.pump();
          expect(dock().motion!.isAnimating, isFalse);
          expect(dock().width, greaterThan(width));
          await drag.up();
          await tester.pump();
          tester.view.physicalSize = const Size(1024, 600);
          await tester.pump();
          expect(dock().motion!.isAnimating, isFalse);
          controls().onOpenAiChat!();
          await tester.pump();
          await settle(tester);
          tester.view.viewInsets = const FakeViewPadding(bottom: 220);
          await tester.pump();
          await settle(tester);
          expect(tester.getRect(surface).width, greaterThan(0));
          expect(tester.element(find.byType(VideoPlayer)), same(texture));
          expect(playback.controller, same(controller));
          expectNoErrorScreen(tester);
          tester.view.resetViewInsets();
          await tester.runAsync(() => playback.stop());
          await close(tester);
        },
      );
    }
  }

  testWidgets('landscape: Escape closes the episode overlay before settings', (
    tester,
  ) async {
    window(tester, const Size(1280, 720));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await settle(tester);
    expect(find.byType(SettingsPanel), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await settle(tester);
    expect(find.byType(EpisodePickerPanel), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(EpisodePickerPanel), findsNothing);
    expect(find.byType(SettingsPanel), findsOneWidget);
    expect(find.byType(VideoPlayerScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(SettingsPanel), findsNothing);
    expect(find.byType(SubtitleSidebar), findsOneWidget);
    expect(
      tester
          .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expectNoErrorScreen(tester);
    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  testWidgets('an externally prepared landscape entry does not adopt or '
      'restart the previous session', (tester) async {
    window(tester, const Size(1280, 720));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(
      host(
        VideoPlayerScreen(
          videoItem: items.last,
          deferPlaybackUntilCurrent: true,
        ),
      ),
    );
    await settle(tester);
    final overlay = find.byType(VideoControlsOverlay);
    final state = tester.state<VideoControlsOverlayState>(overlay);
    expect(playback.currentItem?.id, items.first.id);
    expect(platform.playerIds, [1]);
    expect(
      tester.widget<VideoControlsOverlay>(overlay).mediaItemId,
      items.last.id,
    );
    expect(state.controlsVisible, isFalse);

    await startPlayback(tester, items.last, 2);
    await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.last)));
    await settle(tester);
    expect(tester.state<VideoControlsOverlayState>(overlay), same(state));
    expect(
      tester.widget<VideoControlsOverlay>(overlay).controller,
      playback.controller,
    );
    expect(state.controlsVisible, isFalse);
    expectNoErrorScreen(tester);
    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  testWidgets(
    'landscape: repeated settings shortcut toggles without self-return',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
      await settle(tester);
      for (var visit = 0; visit < 3; visit++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await settle(tester);
        expect(find.byType(SettingsPanel), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await settle(tester);
        expect(find.byType(SettingsPanel), findsNothing);
        expect(find.byType(SubtitleSidebar), findsOneWidget);
      }
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
  );

  testWidgets('desktop back closes a tool before leaving window full screen', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'getBounds') {
        return <String, double>{'x': 0, 'y': 0, 'width': 1280, 'height': 720};
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    window(tester, const Size(1280, 720));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
    await settle(tester);
    settings.isFullScreen = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(SettingsPanel), findsNothing);
    expect(settings.isFullScreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(settings.isFullScreen, isFalse);
    expect(find.byType(VideoPlayerScreen), findsOneWidget);
    expect(calls.where((call) => call.method == 'setFullScreen'), hasLength(1));
    expectNoErrorScreen(tester);
    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  for (final backSource in ['system', 'button', 'escape']) {
    testWidgets('portrait: settings → style returns to the same settings '
        'surface, backSource=$backSource', (tester) async {
      window(tester, const Size(412, 915));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(PortraitVideoScreen(videoItem: items.first)),
      );
      await settle(tester);
      tester
          .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
          .onOpenSettings!();
      await settle(tester);
      final original = tester.element(find.byType(SettingsPanel));
      tester
          .widget<SettingsPanel>(find.byType(SettingsPanel))
          .onOpenSubtitleSettings!();
      await settle(tester);
      expect(find.byType(SubtitleSettingsSheet), findsOneWidget);
      if (backSource == 'system') {
        await tester.binding.handlePopRoute();
      } else if (backSource == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        tester
            .widget<SubtitleSettingsSheet>(find.byType(SubtitleSettingsSheet))
            .onBack!();
      }
      await settle(tester);
      expect(find.byType(SubtitleSettingsSheet), findsNothing);
      expect(tester.element(find.byType(SettingsPanel)), same(original));
      tester.widget<SettingsPanel>(find.byType(SettingsPanel)).onClose();
      await settle(tester);
      expect(find.byType(SettingsPanel), findsNothing);
      expect(find.byType(SubtitleSidebar), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    });
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'Bilibili details → AI → close restores details without changing '
      'subtitle preferences, landscape=$landscape',
      (tester) async {
        window(
          tester,
          landscape ? const Size(1280, 720) : const Size(412, 915),
        );
        // Desktop details share the ordinary reading slot. The portrait
        // choice remains independent of whether that desktop slot is open.
        settings.isLandscapeSubtitleSidebarVisible = landscape;
        settings.bilibiliLandscapeShowsSubtitles = false;
        settings.bilibiliPortraitShowsSubtitles = false;
        settings.bilibiliPlayerPanelOpen = true;
        items.first.sourceRef = const MediaSourceRef(
          value: 'BV1aa411c7mA',
          kind: MediaSourceKind.bilibiliBv,
          bvid: 'BV1aa411c7mA',
          page: 1,
        );
        BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
          details: BilibiliVideoDetailCache(
            fetch: (_) async => throw StateError('offline fixture'),
          ),
        );
        addTearDown(() => BilibiliWatchSources.overrideForTesting = null);
        await startPlayback(tester, items.first, 1);
        await tester.pumpWidget(
          host(
            landscape
                ? VideoPlayerScreen(videoItem: items.first)
                : PortraitVideoScreen(videoItem: items.first),
          ),
        );
        await settle(tester);
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        tester
            .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
            .onOpenAiChat!();
        await settle(tester);
        expect(find.byType(AiChatPanel), findsOneWidget);
        tester.widget<AiChatPanel>(find.byType(AiChatPanel)).onClose!();
        await settle(tester);
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        expect(settings.isLandscapeSubtitleSidebarVisible, landscape);
        expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
        expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
        expectNoErrorScreen(tester);
        await tester.runAsync(() => playback.stop());
        await close(tester);
      },
    );
  }

  testWidgets(
    'a closed desktop reading slot stays closed through an AI visit',
    (tester) async {
      window(tester, const Size(1280, 720));
      settings.isLandscapeSubtitleSidebarVisible = false;
      settings.bilibiliPlayerPanelOpen = true;
      settings.bilibiliLandscapeShowsSubtitles = false;
      items.first.sourceRef = const MediaSourceRef(
        value: 'BV1aa411c7mA',
        kind: MediaSourceKind.bilibiliBv,
        bvid: 'BV1aa411c7mA',
        page: 1,
      );
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        details: BilibiliVideoDetailCache(
          fetch: (_) async => throw StateError('offline fixture'),
        ),
      );
      addTearDown(() => BilibiliWatchSources.overrideForTesting = null);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
      await settle(tester);
      expect(find.byType(BilibiliPlayerPanel), findsNothing);
      tester
          .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
          .onOpenAiChat!();
      await settle(tester);
      expect(find.byType(AiChatPanel), findsOneWidget);
      tester.widget<AiChatPanel>(find.byType(AiChatPanel)).onClose!();
      await settle(tester);
      expect(find.byType(BilibiliPlayerPanel), findsNothing);
      expect(find.byType(VideoPlayerScreen), findsOneWidget);
      expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
      expect(settings.bilibiliPlayerPanelOpen, isTrue);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
  );

  testWidgets(
    'a hidden shared Bilibili slot opened by I closes before the page',
    (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = false;
      settings.isLandscapeSubtitleSidebarVisible = false;
      settings.bilibiliLandscapeShowsSubtitles = true;
      items.first.sourceRef = const MediaSourceRef(
        value: 'BV1aa411c7mA',
        kind: MediaSourceKind.bilibiliBv,
        bvid: 'BV1aa411c7mA',
        page: 1,
      );
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        details: BilibiliVideoDetailCache(
          fetch: (_) async => throw StateError('offline fixture'),
        ),
      );
      addTearDown(() => BilibiliWatchSources.overrideForTesting = null);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
      await settle(tester);
      expect(find.byType(BilibiliPlayerPanel), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await settle(tester);
      expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(BilibiliPlayerPanel), findsNothing);
      expect(find.byType(VideoPlayerScreen), findsOneWidget);
      expect(settings.bilibiliPlayerPanelOpen, isFalse);
      expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
  );

  testWidgets(
    'resizing retains the shared Bilibili destination below two tools',
    (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      settings.isLandscapeSubtitleSidebarVisible = true;
      settings.bilibiliLandscapeShowsSubtitles = false;
      items.first.sourceRef = const MediaSourceRef(
        value: 'BV1aa411c7mA',
        kind: MediaSourceKind.bilibiliBv,
        bvid: 'BV1aa411c7mA',
        page: 1,
      );
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        details: BilibiliVideoDetailCache(
          fetch: (_) async => throw StateError('offline fixture'),
        ),
      );
      addTearDown(() => BilibiliWatchSources.overrideForTesting = null);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
      await settle(tester);
      // An already visible shared slot uses I only to switch its pages.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await settle(tester);
      expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
      expect(find.byType(BilibiliPlayerPanel), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await settle(tester);
      expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await settle(tester);
      tester
          .widget<SettingsPanel>(find.byType(SettingsPanel))
          .onOpenSubtitleSettings!();
      await settle(tester);
      await rebuildPage(tester, const Size(800, 720));
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(SettingsPanel), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      // A desktop reading slot is resizable, so it remains the return
      // destination at 800px; the old separate-panel 640px rule is not used.
      expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('landscape-reading-tabs')),
        findsOneWidget,
      );
      expect(settings.isLandscapeSubtitleSidebarVisible, isTrue);
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      await rebuildPage(tester, const Size(1280, 720));
      expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
      expect(settings.bilibiliPlayerPanelOpen, isTrue);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    },
  );

  for (final landscape in [false, true]) {
    testWidgets('subtitle library → transcription → back restores the library, '
        'landscape=$landscape', (tester) async {
      window(tester, landscape ? const Size(1280, 720) : const Size(412, 915));
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(
        host(
          landscape
              ? VideoPlayerScreen(videoItem: items.first)
              : PortraitVideoScreen(videoItem: items.first),
        ),
      );
      await settle(tester);
      tester
          .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
          .onOpenSubtitleManager!();
      await settle(tester);
      final original = tester.element(find.byType(SubtitleManagementSheet));
      tester
          .widget<SubtitleManagementSheet>(find.byType(SubtitleManagementSheet))
          .onOpenAi();
      await settle(tester);
      expect(find.byType(AiTranscriptionPanel), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(AiTranscriptionPanel), findsNothing);
      expect(
        tester.element(find.byType(SubtitleManagementSheet)),
        same(original),
      );
      tester
          .widget<SubtitleManagementSheet>(find.byType(SubtitleManagementSheet))
          .onClose!();
      await settle(tester);
      expect(find.byType(SubtitleSidebar), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    });
  }

  final pages = <String, Widget Function(VideoItem item)>{
    'landscape': (item) =>
        VideoPlayerScreen(videoItem: item, autoPlayOnEntry: false),
    'portrait': (item) =>
        PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false),
  };

  testWidgets(
    'subtitle seek updates the ambient hold without rebuilding the page',
    (tester) async {
      window(tester, const Size(1280, 720));
      await startPlayback(tester, items.first, 1);
      await tester.runAsync(() => playback.pause());
      await tester.pumpWidget(
        host(pages['landscape']!(items.first), reactivePlayback: true),
      );
      await settle(tester);

      final surface = find.byKey(const ValueKey('landscape-player-surface'));
      final originalSurface = tester.widget(surface);
      final originalControls = tester.widget(find.byType(VideoControlsOverlay));
      final sidebar = tester.widget<SubtitleSidebar>(
        find.byType(SubtitleSidebar, skipOffstage: false).first,
      );
      try {
        sidebar.onItemTap!(const Duration(seconds: 20));
        await tester.pump();
        expect(
          tester
              .widget<AmbientLetterboxLayer>(find.byType(AmbientLetterboxLayer))
              .seekHold,
          isTrue,
        );
        expect(identical(tester.widget(surface), originalSurface), isTrue);
        expect(
          identical(
            tester.widget(find.byType(VideoControlsOverlay)),
            originalControls,
          ),
          isTrue,
        );

        // A second hop extends the same hold rather than rebuilding the player.
        await tester.pump(const Duration(milliseconds: 500));
        sidebar.onItemTap!(const Duration(seconds: 25));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 799));
        expect(
          tester
              .widget<AmbientLetterboxLayer>(find.byType(AmbientLetterboxLayer))
              .seekHold,
          isTrue,
        );
        final heldSurface = tester.widget(surface);
        final heldControls = tester.widget(find.byType(VideoControlsOverlay));
        await tester.pump(const Duration(milliseconds: 1));
        expect(
          tester
              .widget<AmbientLetterboxLayer>(find.byType(AmbientLetterboxLayer))
              .seekHold,
          isFalse,
        );
        expect(identical(tester.widget(surface), heldSurface), isTrue);
        expect(
          identical(
            tester.widget(find.byType(VideoControlsOverlay)),
            heldControls,
          ),
          isTrue,
        );
      } finally {
        await tester.runAsync(() => playback.stop());
        await close(tester);
      }
      expectNoErrorScreen(tester);
    },
  );

  testWidgets('landscape episode navigation still follows playlist changes', (
    tester,
  ) async {
    window(tester, const Size(1280, 720));
    await startPlayback(tester, items.first, 1);
    await tester.runAsync(() => playback.pause());
    await tester.pumpWidget(
      host(pages['landscape']!(items.first), reactivePlayback: true),
    );
    await settle(tester);
    try {
      expect(
        tester
            .widget<VideoControlsOverlay>(find.byType(VideoControlsOverlay))
            .hasNext,
        isTrue,
      );
      playlist.setPlaylist([items.first]);
      playback.debugSeedCloudDriveQualities(const []);
      await tester.pump();
      final controls = tester.widget<VideoControlsOverlay>(
        find.byType(VideoControlsOverlay),
      );
      expect(controls.hasNext, isFalse);
      expect(controls.hasPrevious, isFalse);
    } finally {
      await tester.runAsync(() => playback.stop());
      await close(tester);
    }
    expectNoErrorScreen(tester);
  });

  for (final entry in pages.entries) {
    final name = entry.key;
    final page = entry.value;
    final size = name == 'landscape'
        ? const Size(1280, 720)
        : const Size(412, 915);
    final resized = name == 'landscape'
        ? const Size(1180, 700)
        : const Size(400, 880);

    for (final online in [false, true]) {
      testWidgets(
        '$name subtitle manager opens OCR and returns to the same manager, '
        'online=$online',
        (tester) async {
          window(tester, name == 'landscape' ? const Size(740, 360) : size);
          final item = items.first;
          await startPlayback(tester, item, 1);
          // Reuse the fake controller to exercise a streaming item's panel
          // navigation without depending on a network source resolver.
          if (online) item.path = 'https://example.invalid/ocr-entry.mp4';
          await tester.pumpWidget(host(page(item)));
          await settle(tester);
          tester
              .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
              .onOpenSubtitleManager!();
          await settle(tester);
          final manager = find.byType(SubtitleManagementSheet);
          final original = tester.state(manager);
          final importButton = find.text('导入字幕');
          final ocrButton = find.text('OCR字幕');
          final aiButton = find.text('语音转录');
          expect(ocrButton.hitTestable(), findsOneWidget);
          expect(
            tester.getCenter(ocrButton).dx,
            inExclusiveRange(
              tester.getCenter(importButton).dx,
              tester.getCenter(aiButton).dx,
            ),
          );
          for (final backSource in ['system', 'button', 'escape']) {
            await tester.tap(ocrButton);
            await settle(tester);
            final ocr = find.byType(OcrSubtitlePanel);
            expect(ocr, findsOneWidget);
            expect(tester.widget<OcrSubtitlePanel>(ocr).videoItem, same(item));
            if (backSource == 'system') {
              await tester.binding.handlePopRoute();
            } else if (backSource == 'escape') {
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            } else {
              tester.widget<OcrSubtitlePanel>(ocr).onBack();
            }
            await settle(tester);
            expect(ocr, findsNothing);
            expect(tester.state(manager), same(original));
            expect(ocrButton.hitTestable(), findsOneWidget);
          }
          await tester.tap(aiButton);
          await settle(tester);
          expect(find.byType(AiTranscriptionPanel), findsOneWidget);
          await tester.binding.handlePopRoute();
          await settle(tester);
          expect(tester.state(manager), same(original));
          expectNoErrorScreen(tester);
          await tester.runAsync(() => playback.stop());
          await close(tester);
        },
      );

      testWidgets(
        '$name audio subtitle manager has no OCR entry, online=$online',
        (tester) async {
          window(tester, size);
          final item = items.first..type = MediaType.audio;
          await startPlayback(tester, item, 1);
          if (online) item.path = 'https://example.invalid/ocr-entry.mp3';
          await tester.pumpWidget(host(page(item)));
          await settle(tester);
          tester
              .widget<SubtitleSidebar>(find.byType(SubtitleSidebar))
              .onOpenSubtitleManager!();
          await settle(tester);
          expect(find.byType(SubtitleManagementSheet), findsOneWidget);
          expect(find.text('导入字幕'), findsOneWidget);
          expect(find.text('语音转录'), findsOneWidget);
          expect(find.text('OCR字幕'), findsNothing);
          expect(
            tester
                .widget<SubtitleManagementSheet>(
                  find.byType(SubtitleManagementSheet),
                )
                .onOpenOcrSubtitle,
            isNull,
          );
          expectNoErrorScreen(tester);
          await tester.runAsync(() => playback.stop());
          await close(tester);
        },
      );
    }

    testWidgets(
      '$name subtitles cross a cue boundary between controller samples',
      (tester) async {
        window(tester, size);
        settings.autoScrollSubtitles = false;
        settings.portraitSidebarShowTimestamps = true;
        settings.landscapeSidebarShowTimestamps = true;
        await startPlayback(tester, items.first, 1);
        await tester.runAsync(() async {
          await playback.pause();
          await playback.seekTo(const Duration(milliseconds: 5940));
        });
        playback.setSubtitleState(
          paths: ['timing.srt'],
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 6),
              text: 'Timing previous cue',
            ),
            SubtitleItem(
              index: 1,
              startTime: const Duration(seconds: 6),
              endTime: const Duration(seconds: 12),
              text: 'Timing next cue',
            ),
          ],
          secondary: const [],
        );
        await tester.pumpWidget(host(page(items.first)));
        await settle(tester);
        bool overlayShows(String text) => tester
            .widgetList<SubtitleOverlayGroup>(find.byType(SubtitleOverlayGroup))
            .any(
              (overlay) => overlay.entries.any((entry) => entry.text == text),
            );
        Color? timestampColor(int index) => tester
            .widget<Text>(find.byKey(ValueKey('subtitle-time-$index')))
            .style
            ?.color;
        try {
          expect(overlayShows('Timing previous cue'), isTrue);
          expect(timestampColor(0), Colors.blueAccent);
          final native = playback.controller!.value.position;
          // Simulate the presented frame advancing between native position polls.
          // No controller/service change notification accompanies this frame.
          playback.positionNotifier.value = const Duration(milliseconds: 6005);
          await tester.pump();
          expect(playback.controller!.value.position, native);
          expect(overlayShows('Timing next cue'), isTrue);
          expect(timestampColor(1), Colors.blueAccent);
          expect(timestampColor(0), isNot(Colors.blueAccent));

          final overlays = tester
              .widgetList<SubtitleOverlayGroup>(
                find.byType(SubtitleOverlayGroup),
              )
              .toList();
          playback.positionNotifier.value = const Duration(milliseconds: 6100);
          await tester.pump();
          expect(
            tester.widgetList<SubtitleOverlayGroup>(
              find.byType(SubtitleOverlayGroup),
            ),
            orderedEquals(overlays),
            reason:
                'frames inside the same cue must retain the overlay widgets',
          );

          // A paused offset change must refresh both displays immediately.
          settings.setSubtitleDelay(0.2);
          await tester.pump();
          expect(overlayShows('Timing previous cue'), isTrue);
          expect(timestampColor(0), Colors.blueAccent);
          playback.positionNotifier.value = const Duration(milliseconds: 6205);
          await tester.pump();
          expect(overlayShows('Timing next cue'), isTrue);
          expect(timestampColor(1), Colors.blueAccent);

          settings.setSubtitleDelay(-0.2);
          playback.positionNotifier.value = const Duration(milliseconds: 5805);
          await tester.pump();
          expect(overlayShows('Timing next cue'), isTrue);
          expect(timestampColor(1), Colors.blueAccent);
          playback.positionNotifier.value = const Duration(milliseconds: 5795);
          await tester.pump();
          expect(overlayShows('Timing previous cue'), isTrue);
          expect(timestampColor(0), Colors.blueAccent);
        } finally {
          await tester.runAsync(() => playback.stop());
          await close(tester);
        }
        expectNoErrorScreen(tester);
      },
    );

    testWidgets('$name transcript syncs while its page controller is stale', (
      tester,
    ) async {
      window(tester, size);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);

      final oldController = playback.controller!;
      try {
        playback.clearController();
        playback.setSubtitleState(
          paths: ['official-ai.srt'],
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
              text: 'Automatically loaded AI',
            ),
          ],
          secondary: const [],
        );
        await tester.pump();
        final sidebars = tester.widgetList<SubtitleSidebar>(
          find.byType(SubtitleSidebar, skipOffstage: false),
        );
        expect(sidebars, isNotEmpty);
        expect(sidebars.first.subtitles.map((cue) => cue.text), [
          'Automatically loaded AI',
        ]);
      } finally {
        await tester.runAsync(() async {
          await playback.stop();
          await oldController.dispose();
        });
        await close(tester);
      }
      expectNoErrorScreen(tester);
    });

    testWidgets('$name page: after playback is stopped, the page and the '
        'page opened again show the video normally', (tester) async {
      window(tester, size);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);

      await tester.runAsync(() => playback.stop());
      expect(platform.playerIds, isEmpty, reason: 'player 1 was disposed');
      await settle(tester);
      await rebuildPage(tester, resized);
      expectNoErrorScreen(tester);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsNothing);
      await close(tester);

      // Open the playback page again after the stop.
      await startPlayback(tester, items.first, 2);
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);
      expectNoErrorScreen(tester);
      expect(find.byKey(const ValueKey('fake-video-view-2')), findsOneWidget);
      // Stop inside the test so the playing session's ticker is gone before
      // the tree is torn down.
      await tester.runAsync(() => playback.stop());
      await close(tester);
    });

    testWidgets('$name page: a count-based sleep timer that ends with the '
        'queue keeps the page on a live player, also after re-entering', (
      tester,
    ) async {
      window(tester, size);
      await startPlayback(tester, items.first, 1);
      await tester.runAsync(() => playback.sleepTimer.scheduleAfterItems(5));
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);

      await finishCurrent(tester, 1);
      await tester.runAsync(() async {
        await _until(() => platform.playerIds.contains(2));
        platform.initializePlayer(2);
        await _until(
          () =>
              playback.currentItem?.id == items[1].id &&
              playback.state == PlaybackState.playing,
        );
      });
      await settle(tester);

      await finishCurrent(tester, 2);
      await tester.runAsync(() async {
        await _until(() => !playback.sleepTimer.isActive);
        await _until(() => playback.state == PlaybackState.paused);
      });
      expect(playback.sleepTimer.isActive, isFalse);
      expect(playback.currentItem?.id, items[1].id);
      expect(platform.playerIds, contains(2));
      await settle(tester);
      await rebuildPage(tester, resized);
      expectNoErrorScreen(tester);
      expect(find.byKey(const ValueKey('fake-video-view-2')), findsOneWidget);
      await close(tester);

      // Re-enter the playback page after the timer ended.
      await tester.pumpWidget(host(page(items[1])));
      await settle(tester);
      expectNoErrorScreen(tester);
      expect(find.byKey(const ValueKey('fake-video-view-2')), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('portrait page: after switching videos in fullscreen, coming '
      'back shows the new video normally', (tester) async {
    window(tester, const Size(412, 915));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(
      host(PortraitVideoScreen(videoItem: items.first, autoPlayOnEntry: false)),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);

    // Into fullscreen: the landscape page goes on top of this one.
    // The top bar has a window fullscreen button too; the player's own one
    // sits in the video area below it.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.fullscreen).last);
    // The device turns to landscape with it.
    tester.view.physicalSize = const Size(1280, 720);
    await settle(tester);
    expect(find.byType(VideoPlayerScreen), findsOneWidget);

    // 下一集 inside fullscreen: the service moves on to player 2 while the
    // portrait page is still underneath.
    await startPlayback(tester, items[1], 2);
    expect(platform.playerIds, isNot(contains(1)));
    await settle(tester);
    expectNoErrorScreen(tester);

    // Back to the portrait page.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);
    // The device turns back once the fullscreen page is gone.
    tester.view.physicalSize = const Size(412, 915);
    await settle(tester);
    expectNoErrorScreen(tester);
    expect(find.byType(VideoPlayerScreen), findsNothing);
    expect(find.byKey(const ValueKey('fake-video-view-1')), findsNothing);
    expect(find.byKey(const ValueKey('fake-video-view-2')), findsOneWidget);

    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  testWidgets(
    'cloud AI subtitles keep loading across a fullscreen round trip',
    (tester) async {
      window(tester, const Size(412, 915));
      // Online startup waits for a decoded frame, independently of subtitle
      // discovery. Model that native progress while the subtitle gate is held.
      platform.reportDecodedFrameOnPlay = true;
      final item = cloudItem(id: 'fullscreen-ai');
      final cloud = CloudPlaybackFake();
      final source = CloudOfficialSubtitleFake()..textGate = Completer<void>();
      final tracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item}, root),
      );
      CloudDriveSubtitleTracks.overrideForTesting = tracks;
      playback.attachCloudDrivePlayback(cloud);
      try {
        await startPlayback(tester, item, 1);
        await tester.runAsync(() => _until(() => source.textCalls == 1));
        expect(source.textCalls, 1);
        await tester.pumpWidget(
          host(PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false)),
        );
        await settle(tester);
        final intent = playback.subtitleIntentGenerationForTest;

        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.fullscreen).last,
        );
        tester.view.physicalSize = const Size(1280, 720);
        await settle(tester);
        expect(find.byType(VideoPlayerScreen), findsOneWidget);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await settle(tester);
        tester.view.physicalSize = const Size(412, 915);
        await settle(tester);
        expect(
          playback.subtitleIntentGenerationForTest,
          intent,
          reason: 'Changing layouts must not clear an automatic selection',
        );

        await tester.runAsync(() async {
          source.textGate!.complete();
          await _until(() => playback.subtitles.isNotEmpty);
        });
        await settle(tester);
        expect(playback.subtitles.map((cue) => cue.text), ['自动字幕']);
        expect(playback.subtitlePaths, hasLength(1));
        final sidebar = tester.widget<SubtitleSidebar>(
          find.byType(SubtitleSidebar),
        );
        expect(sidebar.subtitles.map((cue) => cue.text), ['自动字幕']);
        expect(source.calls, 1);
        expect(source.textCalls, 1);
        expectNoErrorScreen(tester);
      } finally {
        if (!source.textGate!.isCompleted) source.textGate!.complete();
        await tester.runAsync(() => playback.stop());
        await close(tester);
        CloudDriveSubtitleTracks.overrideForTesting = null;
        tracks.dispose();
        await tester.runAsync(() => cloud.gatewayImpl.close());
      }
    },
  );

  testWidgets('format repair is offered in the existing player error area', (
    tester,
  ) async {
    window(tester, const Size(844, 390));
    await startPlayback(tester, items.first, 1);
    await tester.pumpWidget(host(VideoPlayerScreen(videoItem: items.first)));
    await settle(tester);
    final controller = playback.controller!;
    final created = platform.creationRequests;
    controller.value = controller.value.copyWith(
      errorDescription: 'HevcConfig fixture',
    );
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('playback-repair-retry')), findsOneWidget);
    expect(find.textContaining('可尝试转为 H.264'), findsOneWidget);
    expect(platform.creationRequests, created);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => playback.stop());
    await close(tester);
  });

  for (final entry in pages.entries) {
    final name = entry.key;
    final page = entry.value;
    final size = name == 'landscape'
        ? const Size(1280, 720)
        : const Size(412, 915);
    final resized = name == 'landscape'
        ? const Size(1180, 700)
        : const Size(400, 880);

    testWidgets('$name page: failed loading exposes a fresh paused retry', (
      tester,
    ) async {
      window(tester, size);
      await startPlayback(tester, items.first, 1);
      await tester.runAsync(playback.pause);
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);
      await tester.runAsync(() async {
        final opening = playback.play(
          items.first,
          startPosition: const Duration(seconds: 17),
          autoPlay: false,
          forceRecreate: true,
        );
        await _until(() => platform.playerIds.contains(2));
        platform.failPlayer(2);
        await opening;
      });
      await settle(tester);
      expect(playback.state, PlaybackState.error);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsNothing);
      expectNoErrorScreen(tester);

      await tester.tap(find.text('重试'));
      await waitForPreview(tester, () => platform.playerIds.contains(3));
      platform.initializePlayer(3);
      await waitForPreview(
        tester,
        () => playback.state == PlaybackState.paused,
      );
      await settle(tester);
      expect(playback.state, PlaybackState.paused);
      expect(playback.position, const Duration(seconds: 17));
      expect(platform.creationRequests, 3);
      expect(find.text('重试'), findsNothing);
      expect(find.byKey(const ValueKey('fake-video-view-3')), findsOneWidget);
      expectNoErrorScreen(tester);
      await tester.runAsync(() => playback.stop());
      await close(tester);
    });

    testWidgets('$name page: a rebuild never draws a player the service no '
        'longer holds, even before the page hears about it', (tester) async {
      window(tester, size);
      await startPlayback(tester, items.first, 1);
      await tester.pumpWidget(host(page(items.first)));
      await settle(tester);
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsOneWidget);

      // The service lets go of player 1 without notifying anyone
      // (clearController does not call notifyListeners), and the player is
      // then disposed. The page has not been told.
      final released = playback.controller!;
      await tester.runAsync(() async {
        playback.clearController();
        await released.dispose();
      });
      expect(playback.controller, isNull);
      expect(platform.playerIds, isNot(contains(1)));
      platform.buildViewCalls.clear();

      // Something else rebuilds the page.
      await rebuildPage(tester, resized);
      expectNoErrorScreen(tester);
      expect(platform.buildViewCalls, isNot(contains(1)));
      expect(find.byKey(const ValueKey('fake-video-view-1')), findsNothing);

      await tester.runAsync(() => playback.stop());
      await close(tester);
    });
  }
}
