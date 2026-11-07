import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/playback_mode_button.dart';

import 'support/fake_video_player_platform.dart';

void main() {
  testWidgets('real mini-player controls receive keyboard focus and Space', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await library.createCollection('Only folder', null, id: 'only');
    final playback = MediaPlaybackService();
    await playback.stop();
    final previousPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    final initiallyMuted = playback.isMuted;
    final item = VideoItem(
      id: 'mini-preview',
      path: 'preview.mp4',
      title: 'Preview',
      durationMs: 60000,
      lastUpdated: 0,
    );
    final queue = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
    )..setPlaylist([item]);
    playback.publishRestoredSessionPreview(item, const Duration(seconds: 3));
    final controller = VideoPlayerController.file(File('preview.mp4'));
    await controller.initialize();
    await playback.setController(controller);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      if (playback.isMuted != initiallyMuted) await playback.toggleMute();
      await playback.stop();
      VideoPlayerPlatform.instance = previousPlatform;
      queue.dispose();
      library.resetLibraryForTesting();
      settings.resetForTest();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: queue),
          ChangeNotifierProvider.value(value: BatchImportService()),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const MediaLibraryShell(
            home: HomeScreen(returnToSearchResults: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardMiniPlayer.hasFocus, isTrue);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Slider>(),
      isNull,
      reason: 'down from a card enters the row above the progress bar',
    );

    Finder blueOutline(Finder child) => find.ancestor(
      of: child,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border?.top.color ==
                Colors.lightBlueAccent,
      ),
    );
    final title = find.text('Preview');
    Focus.of(tester.element(title)).requestFocus();
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(title)).hasPrimaryFocus, isTrue);
    expect(blueOutline(title), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final mode = find.byKey(const ValueKey('mini-playback-mode'));
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlaybackModeButton>(),
      isNotNull,
    );
    expect(blueOutline(mode), findsOneWidget);
    final previousMode = queue.playbackMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(queue.playbackMode, isNot(previousMode));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Tooltip>()
          ?.message,
      '播放列表',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(title)).hasPrimaryFocus,
      isTrue,
      reason:
          'focus after left: ${FocusManager.instance.primaryFocus} '
          'tooltip ${FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Tooltip>()?.message} '
          'ink ${FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<InkWell>()?.key}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Slider>(),
      isNotNull,
    );
    expect(
      blueOutline(find.byKey(const ValueKey('mini-playback-progress'))),
      findsOneWidget,
    );
    final beforeSeek = playback.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(playback.position, greaterThan(beforeSeek));
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Slider>(),
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(playback.position, beforeSeek);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(title)).hasPrimaryFocus, isTrue);

    bool muteHasFocus() {
      final context = FocusManager.instance.primaryFocus?.context;
      final tooltip = context?.findAncestorWidgetOfExactType<Tooltip>();
      return tooltip?.message == (initiallyMuted ? '取消静音' : '静音');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(muteHasFocus(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.isMuted, isNot(initiallyMuted));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardMiniPlayer.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);

    var enteredPlayer = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: queue),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: MediaLibrarySpatialNavigation(
            child: MediaLibraryKeyboardMiniPlayer(
              child: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: MiniPlaybackCard(
                    isVisible: true,
                    onTap: () => enteredPlayer++,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('Preview'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(enteredPlayer, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('down from a card above the cover focuses the title row', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 60000,
        lastUpdated: 0,
      ),
      Duration.zero,
    );
    final region = GlobalKey<MediaLibraryKeyboardRegionState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: MediaLibrarySpatialNavigation(
              child: Stack(
                children: [
                  MediaLibraryKeyboardRegion(
                    key: region,
                    surface: () => 'library',
                    orderedIds: () => const ['card'],
                    selectionMode: () => false,
                    selectedIds: () => const <String>{},
                    onSelectionChanged: (_) {},
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 96,
                        height: 72,
                        child: MediaLibraryKeyboardItem(
                          itemId: 'card',
                          selected: false,
                          selectionMode: false,
                          onActivate: () {},
                          child: const ColoredBox(color: Color(0xFF1565C0)),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: MediaLibraryKeyboardMiniPlayer(
                      child: MiniPlaybackCard(isVisible: true, onTap: () {}),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(region.currentState!.focusInitial(), isTrue);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused?.findAncestorWidgetOfExactType<Slider>(), isNull);
    expect(
      focused?.findAncestorWidgetOfExactType<InkWell>()?.key,
      const ValueKey('mini-playback-title'),
    );
  });
}
