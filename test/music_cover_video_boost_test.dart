import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';
import 'package:video_player_app/widgets/music_cover_video_stage.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    MediaPlaybackService().debugClearMusicCoverVideoSurface();
    MediaPlaybackService().endTemporaryPlaybackSpeed();
  });

  test('long-press speed label uses a multiplication sign', () {
    expect(musicLongPressSpeedLabel(2), '2×');
    expect(musicLongPressSpeedLabel(2.0), '2×');
    expect(musicLongPressSpeedLabel(1.5), '1.5×');
    expect(musicLongPressSpeedLabel(3.04), '3×');
  });

  testWidgets('landscape cover stays below the floating tools', (tester) async {
    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService();

    Future<void> expectClearance(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: const MaterialApp(home: MusicPlayerScreen(title: 'Clearance')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final panel = find.byKey(const ValueKey('music-landscape-left-panel'));
      final stage = find.byKey(const ValueKey('music-cover-video-stage'));
      expect(
        tester.getTopLeft(stage).dy,
        greaterThanOrEqualTo(
          tester.getTopLeft(panel).dy + musicLandscapeToolbarClearance - 0.1,
        ),
      );
    }

    await expectClearance(const Size(1180, 820));
    await expectClearance(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });

  testWidgets('the speed label sits under the elapsed time in the same style', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MusicPlaybackControls(
            totalDuration: Duration(minutes: 3),
            currentPosition: Duration(seconds: 12),
            progress: 0.1,
            temporarySpeedLabel: '2×',
          ),
        ),
      ),
    );
    final time = tester.widget<Text>(
      find.byKey(const ValueKey('music-current-time')),
    );
    final speed = tester.widget<Text>(
      find.byKey(const ValueKey('music-temporary-speed-label')),
    );
    expect(speed.data, '2×');
    expect(speed.style!.fontFamily, time.style!.fontFamily);
    expect(speed.style!.fontSize, time.style!.fontSize);
    expect(speed.style!.fontWeight, time.style!.fontWeight);
    expect(speed.style!.color, time.style!.color);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('music-temporary-speed-label')))
          .dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('music-current-time'))).dy,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MusicPlaybackControls(
            totalDuration: Duration(minutes: 3),
            currentPosition: Duration(seconds: 12),
            progress: 0.1,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('music-temporary-speed-label')),
      findsNothing,
    );
  });

  testWidgets('every point on the cover and the video boosts, and release '
      'restores', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? label;
    late StateSetter update;
    var framesReady = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MusicAlbumCover(
                  title: 'Outside the card',
                  artist: 'Channel',
                  coverSize: 180,
                  infoWidth: 220,
                  maxVideoWidth: 420,
                  isVideo: true,
                  videoGestureEnabled: true,
                  debugVideoFramesReady: framesReady,
                  debugVideoAspectRatio: 9 / 16,
                  onTemporarySpeedChanged: (value) => label = value,
                  onExitTrigger: () {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final stage = find.byKey(const ValueKey('music-cover-video-stage'));
    final origin = tester.getTopLeft(stage);
    final size = tester.getSize(stage);

    Future<void> hold(Offset point) async {
      label = null;
      final gesture = await tester.startGesture(point);
      await tester.pump(kLongPressTimeout);
      expect(label, '2×');
      await gesture.up();
      await tester.pump();
      expect(label, isNull);
    }

    await hold(origin + Offset(size.width / 2, size.height / 2));
    await hold(origin + const Offset(4, 4));
    await hold(origin + Offset(size.width - 4, 4));
    await hold(origin + Offset(4, size.height - 4));
    await hold(origin + Offset(size.width - 4, size.height - 4));

    label = null;
    final titleGesture = await tester.startGesture(
      tester.getCenter(find.text('Outside the card')),
    );
    await tester.pump(kLongPressTimeout);
    expect(label, isNull);
    await titleGesture.up();
    await tester.pump();

    update(() => framesReady = true);
    await tester.pump();
    await _doubleTap(tester, stage);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    final videoOrigin = tester.getTopLeft(stage);
    final videoSize = tester.getSize(stage);
    // 9:16 stays in the square and leaves a blurred margin on both sides.
    await hold(videoOrigin + Offset(6, videoSize.height / 2));
    await hold(videoOrigin + Offset(videoSize.width - 6, videoSize.height / 2));
    await hold(videoOrigin + Offset(videoSize.width / 2, videoSize.height / 2));
  });

  for (final sample in [
    (size: const Size(568, 320), platform: TargetPlatform.android, scale: 1.0),
    (size: const Size(844, 390), platform: TargetPlatform.iOS, scale: 1.0),
    (size: const Size(844, 390), platform: TargetPlatform.android, scale: 1.8),
    (size: const Size(1180, 820), platform: TargetPlatform.android, scale: 1.0),
    (size: const Size(1280, 800), platform: TargetPlatform.windows, scale: 1.8),
  ]) {
    testWidgets('long-press video speed keeps player layout fixed at $sample', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = sample.platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(sample.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = SettingsService()..resetForTest();
      final playback = MediaPlaybackService()
        ..debugOverrideStreamQualityChrome(
          item: VideoItem(
            id: 'boost-layout',
            path: 'boost-layout.mp4',
            title: 'Landscape video',
            type: MediaType.video,
            durationMs: 180000,
            lastUpdated: 0,
          ),
        );
      addTearDown(() => playback.debugOverrideStreamQualityChrome());
      var playPresses = 0, previousPresses = 0, nextPresses = 0;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(sample.scale)),
              child: child!,
            ),
            home: MusicPlayerScreen(
              debugVideoFramesReady: true,
              onPlayPause: () => playPresses++,
              onPrevious: () => previousPresses++,
              onNext: () => nextPresses++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final stage = find.byKey(const ValueKey('music-cover-video-stage'));
      await _doubleTap(tester, stage);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('music-cover-video-surface')),
        findsOneWidget,
      );
      final fixedWidgets = [
        find.byType(MusicPlaybackControls),
        stage,
        find.byKey(const ValueKey('music-landscape-lyric-panel')),
        find.byKey(const ValueKey('music-progress-slider')),
        find.byKey(const ValueKey('music-current-time')),
        find.byKey(const ValueKey('music-remaining-time')),
        find.byKey(const ValueKey('music-landscape-subtitle-management')),
        find.byKey(const ValueKey('music-play-pause-button')),
        find.byTooltip('上一曲 (P)'),
        find.byTooltip('下一曲 (N)'),
        find.byTooltip('音量'),
        find.byTooltip('页面设置 (S)'),
      ];
      final before = {
        for (final finder in fixedWidgets) finder: tester.getRect(finder),
      };
      final label = find.byKey(const ValueKey('music-temporary-speed-label'));
      expect(label, findsNothing);

      final gesture = await tester.startGesture(tester.getCenter(stage));
      await tester.pump(kLongPressTimeout);
      expect(tester.widget<Text>(label).data, '2×');
      for (final entry in before.entries) {
        expect(tester.getRect(entry.key), entry.value, reason: '${entry.key}');
      }
      final labelRect = tester.getRect(label);
      final timeRect = tester.getRect(
        find.byKey(const ValueKey('music-current-time')),
      );
      expect(labelRect.left, timeRect.left);
      expect(labelRect.top, closeTo(timeRect.bottom, .1));
      expect(
        labelRect.overlaps(
          tester.getRect(find.byIcon(Icons.volume_up_outlined)),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(label, findsNothing);
      for (final entry in before.entries) {
        expect(tester.getRect(entry.key), entry.value, reason: '${entry.key}');
      }
      await tester.tap(find.byKey(const ValueKey('music-play-pause-button')));
      await tester.tap(find.byIcon(CupertinoIcons.backward_fill));
      await tester.tap(find.byIcon(CupertinoIcons.forward_fill));
      expect([playPresses, previousPresses, nextPresses], [1, 1, 1]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a drag before the hold finishes does not boost', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? label;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicCoverVideoStage(
            coverSize: 160,
            maxFrameWidth: 320,
            borderRadius: 8,
            itemId: 'drag',
            isVideo: true,
            gestureEnabled: true,
            onTemporarySpeedChanged: (value) => label = value,
            cover: const ColoredBox(color: Color(0xFF224466)),
          ),
        ),
      ),
    );
    await tester.pump();
    final start = tester.getCenter(
      find.byKey(const ValueKey('music-cover-video-stage')),
    );
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(kLongPressTimeout);
    expect(label, isNull);
    await gesture.up();
  });
}

Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}
