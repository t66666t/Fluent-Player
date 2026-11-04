import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowManagerChannel = MethodChannel('window_manager');
  final windowManagerCalls = <MethodCall>[];

  setUp(() {
    windowManagerCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          windowManagerCalls.add(call);
          if (call.method == 'getBounds') {
            return <String, double>{
              'x': 0,
              'y': 0,
              'width': 1280,
              'height': 720,
            };
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, null);
  });

  testWidgets('music shortcuts survive focus loss after full screen changes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final settings = SettingsService()..resetForTest();
    final mediaPlayback = MediaPlaybackService();
    var playPauseCount = 0;
    final seekRequests = <Duration>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: mediaPlayback,
          ),
        ],
        child: MaterialApp(
          home: MusicPlayerScreen(
            onPlayPause: () => playPauseCount++,
            onSeek: seekRequests.add,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();

    expect(settings.isFullScreen, isTrue);
    expect(
      windowManagerCalls.any(
        (call) =>
            call.method == 'setFullScreen' &&
            (call.arguments as Map<Object?, Object?>)['isFullScreen'] == true,
      ),
      isTrue,
    );

    // A native full-screen transition can clear Flutter's primary focus.
    // The music player must continue receiving shortcuts just like the video
    // player, even before a user clicks the page again.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(settings.isFullScreen, isFalse);
    expect(find.byType(MusicPlayerScreen), findsOneWidget);
    expect(
      windowManagerCalls.any(
        (call) =>
            call.method == 'setFullScreen' &&
            (call.arguments as Map<Object?, Object?>)['isFullScreen'] == false,
      ),
      isTrue,
    );

    final wasMuted = mediaPlayback.isMuted;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(mediaPlayback.isMuted, !wasMuted);

    // Restore the singleton playback service for other tests.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(mediaPlayback.isMuted, wasMuted);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(playPauseCount, 1);
    expect(seekRequests, hasLength(2));

    final initialVolume = mediaPlayback.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(mediaPlayback.volume, (initialVolume - 0.05).clamp(0.0, 1.0));
    await mediaPlayback.setVolume(initialVolume);

    // Keep the providers mounted for the frame in which MusicPlayerScreen is
    // disposed because the screen detaches its playback listener in dispose().
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: mediaPlayback,
          ),
        ],
        child: const SizedBox.shrink(),
      ),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('music page commands respect editing, modifiers and loading', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService.forTesting();
    final input = TextEditingController(text: 'draft');
    final inputFocus = FocusNode();
    addTearDown(input.dispose);
    addTearDown(inputFocus.dispose);
    var previous = 0, next = 0;
    Widget player({bool loading = false}) => MusicPlayerScreen(
      followCurrentSession: false,
      isLoading: loading,
      onPrevious: () => previous++,
      onNext: () => next++,
      transcriptFallback: Center(
        child: TextField(controller: input, focusNode: inputFocus),
      ),
    );
    Widget host(Widget page) =>
        _shortcutHost(settings: settings, playback: playback, child: page);
    await tester.pumpWidget(host(player()));
    await tester.pump();
    inputFocus.requestFocus();
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyZ,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect((previous, next), (0, 0));
    expect(
      find.byKey(const ValueKey('music-page-settings-panel')),
      findsNothing,
    );
    expect(find.byType(Dialog), findsNothing);
    expect(inputFocus.hasFocus, isTrue);

    inputFocus.unfocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect((previous, next), (0, 0));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    expect((previous, next), (1, 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('music-page-settings-panel')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('music-page-settings-panel')),
      findsNothing,
    );

    // Detached podcast previews have no active session or episode picker.
    for (final key in [
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyL,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(find.byType(Dialog), findsNothing);

    await tester.pumpWidget(host(player(loading: true)));
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyZ,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect((previous, next), (1, 1));
    expect(
      find.byKey(const ValueKey('music-page-settings-panel')),
      findsNothing,
    );
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets(
    'music session shortcuts open the existing tools and shield keys',
    (tester) async {
      final settings = SettingsService()..resetForTest();
      final playback = MediaPlaybackService.forTesting();
      final playlist = PlaylistManager(
        queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      );
      final item = VideoItem(
        id: 'keyboard-track',
        path: 'https://example.test/keyboard-track.mp3',
        title: 'Keyboard track',
        type: MediaType.audio,
        durationMs: 60000,
        lastUpdated: 0,
      );
      playback.debugSeedCurrentItem(item);
      playlist.setPlaylist([item]);
      final navigator = GlobalKey<NavigatorState>();
      final observer = _ShortcutRoutes();
      var next = 0;
      Widget host(Widget page) => _shortcutHost(
        settings: settings,
        playback: playback,
        playlist: playlist,
        navigatorKey: navigator,
        observer: observer,
        child: page,
      );
      await tester.pumpWidget(host(MusicPlayerScreen(onNext: () => next++)));
      await tester.pump();
      expect(find.byTooltip('选集 (G)'), findsOneWidget);
      expect(find.byTooltip('AI 对话 (W)'), findsOneWidget);
      expect(find.byTooltip('下一曲 (N)'), findsOneWidget);
      expect(find.byTooltip('字幕管理 (L)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(EpisodePickerPanel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(next, 0);
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 350));

      // Verify the existing modal entry points without loading their unrelated
      // subtitle discovery or AI network dependencies in this keyboard test.
      for (final key in [LogicalKeyboardKey.keyL, LogicalKeyboardKey.keyW]) {
        final count = observer.pushed.length;
        await tester.sendKeyEvent(key);
        expect(observer.pushed, hasLength(count + 1));
        expect(observer.pushed.last, isA<PopupRoute<void>>());
        navigator.currentState!.removeRoute(observer.pushed.last);
        await tester.pump();
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('定时关闭'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(next, 0);
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(next, 1);
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.pump();
    },
  );
}

Widget _shortcutHost({
  required SettingsService settings,
  required MediaPlaybackService playback,
  required Widget child,
  PlaylistManager? playlist,
  GlobalKey<NavigatorState>? navigatorKey,
  NavigatorObserver? observer,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: settings),
    ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
    if (playlist != null)
      ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
  ],
  child: MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [?observer],
    home: child,
  ),
);

class _ShortcutRoutes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}
