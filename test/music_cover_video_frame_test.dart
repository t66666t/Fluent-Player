import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';
import 'package:video_player_app/widgets/music_cover_video_frame.dart';
import 'package:video_player_app/widgets/music_cover_video_stage.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(MediaPlaybackService().debugClearMusicCoverVideoSurface);

  test('cover video frame keeps the cover height for every picture shape', () {
    const samples = <(double, double, double)>[
      (200, 480, 9 / 16),
      (200, 480, 1),
      (200, 480, 1.05),
      (84.8, 320, 16 / 9),
      (66.6, 236, 16 / 9),
      (380, 680, 16 / 9),
      (380, 960, 16 / 9),
      (380, 960, 21 / 9),
      (380, 960, 4),
      (200, 220, 1.19),
      (200, 220, 16 / 9),
    ];
    for (final (cover, maxWidth, aspect) in samples) {
      final frame = layoutMusicCoverVideoFrame(
        coverSize: cover,
        maxWidth: maxWidth,
        aspectRatio: aspect,
      );
      expect(frame.height, cover, reason: 'aspect $aspect');
      expect(frame.width, greaterThan(0));
      expect(frame.width, lessThanOrEqualTo(maxWidth + 0.01));
    }
  });

  test('portrait and square pictures stay in the cover square', () {
    final portrait = layoutMusicCoverVideoFrame(
      coverSize: 200,
      maxWidth: 480,
      aspectRatio: 9 / 16,
    );
    expect(portrait.width, 200);
    expect(portrait.fit, BoxFit.contain);
    expect(portrait.usesBackdrop, isTrue);

    final square = layoutMusicCoverVideoFrame(
      coverSize: 200,
      maxWidth: 480,
      aspectRatio: 1.05,
    );
    expect(square.width, 200);
    expect(square.fit, BoxFit.cover);
    expect(square.usesBackdrop, isFalse);
  });

  test('widescreen pictures grow inside the panel and letterbox past it', () {
    final phone = layoutMusicCoverVideoFrame(
      coverSize: 84.8,
      maxWidth: 320,
      aspectRatio: 16 / 9,
    );
    expect(phone.width, closeTo(84.8 * 16 / 9, 0.01));
    expect(phone.fit, BoxFit.fill);
    expect(phone.usesBackdrop, isFalse);

    final desktop = layoutMusicCoverVideoFrame(
      coverSize: 380,
      maxWidth: 960,
      aspectRatio: 16 / 9,
    );
    expect(desktop.width, closeTo(380 * 16 / 9, 0.01));
    expect(desktop.fit, BoxFit.fill);

    final cinema = layoutMusicCoverVideoFrame(
      coverSize: 380,
      maxWidth: 960,
      aspectRatio: 21 / 9,
    );
    expect(cinema.width, closeTo(380 * 21 / 9, 0.01));
    expect(cinema.fit, BoxFit.fill);
    expect(cinema.usesBackdrop, isFalse);

    final clamped = layoutMusicCoverVideoFrame(
      coverSize: 380,
      maxWidth: 960,
      aspectRatio: 4,
    );
    expect(clamped.width, 960);
    expect(clamped.height, 380);
    expect(clamped.fit, BoxFit.contain);
    expect(clamped.usesBackdrop, isTrue);

    final slightCrop = layoutMusicCoverVideoFrame(
      coverSize: 200,
      maxWidth: 220,
      aspectRatio: 1.19,
    );
    expect(slightCrop.width, 220);
    expect(slightCrop.fit, BoxFit.cover);
    expect(slightCrop.usesBackdrop, isFalse);

    final heavyCrop = layoutMusicCoverVideoFrame(
      coverSize: 200,
      maxWidth: 220,
      aspectRatio: 16 / 9,
    );
    expect(heavyCrop.width, 220);
    expect(heavyCrop.fit, BoxFit.contain);
    expect(heavyCrop.usesBackdrop, isTrue);
  });

  test('a missing aspect ratio falls back to the still cover', () {
    final frame = layoutMusicCoverVideoFrame(
      coverSize: 200,
      maxWidth: 400,
      aspectRatio: double.nan,
    );
    expect(frame.width, 200);
    expect(frame.height, 200);
    expect(frame.fit, BoxFit.cover);
    expect(frame.usesBackdrop, isFalse);
  });

  test('only a landscape viewport arms the cover gesture', () {
    expect(musicPlayerUsesCoverVideoGesture(const Size(844, 390)), isTrue);
    expect(musicPlayerUsesCoverVideoGesture(const Size(568, 320)), isTrue);
    expect(musicPlayerUsesCoverVideoGesture(const Size(1366, 1024)), isTrue);
    expect(musicPlayerUsesCoverVideoGesture(const Size(1180, 820)), isTrue);
    expect(musicPlayerUsesCoverVideoGesture(const Size(1024, 1366)), isFalse);
    expect(musicPlayerUsesCoverVideoGesture(const Size(390, 844)), isFalse);
  });

  testWidgets('landscape flip keeps the title still and only widens the card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MusicAlbumCover(
              title: 'Wide episode',
              artist: 'Channel',
              coverSize: 180,
              infoWidth: 280,
              maxVideoWidth: 420,
              isVideo: true,
              videoGestureEnabled: true,
              debugVideoFramesReady: true,
              debugVideoAspectRatio: 16 / 9,
              onExitTrigger: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final title = find.text('Wide episode');
    final stage = find.byKey(const ValueKey('music-cover-video-stage'));
    final titleBefore = tester.getTopLeft(title);
    final stageBefore = tester.getSize(stage);
    expect(stageBefore.height, 180);
    expect(stageBefore.width, 180);

    await _doubleTap(tester, stage);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.getTopLeft(title), titleBefore);
    final stageAfter = tester.getSize(stage);
    expect(stageAfter.height, 180);
    expect(stageAfter.width, closeTo(180 * 16 / 9, 1));
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsOneWidget,
    );
    expect(MediaPlaybackService().musicCoverOwnsVideoSurface, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('audio, portrait and wide portrait do not arm the flip', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService();

    Future<void> pumpAt(Size size, {bool forceVideo = false}) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            home: MusicPlayerScreen(
              title: 'Still cover',
              debugLandscapeVideo: forceVideo,
              debugVideoFramesReady: forceVideo,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
    }

    await pumpAt(const Size(390, 844));
    expect(find.byType(MusicCoverVideoStage), findsNothing);

    await pumpAt(const Size(1024, 1366), forceVideo: true);
    expect(
      tester
          .widget<MusicCoverVideoStage>(find.byType(MusicCoverVideoStage))
          .gestureEnabled,
      isFalse,
    );

    await pumpAt(const Size(844, 390));
    final controls = find.byType(MusicPlaybackControls);
    final lyrics = find.byKey(const ValueKey('music-landscape-lyric-panel'));
    final controlsBefore = tester.getTopLeft(controls);
    final lyricsBefore = tester.getTopLeft(lyrics);
    await _doubleTap(
      tester,
      find.byKey(const ValueKey('music-cover-video-stage')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.getTopLeft(controls), controlsBefore);
    expect(tester.getTopLeft(lyrics), lyricsBefore);
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsNothing,
    );

    addTearDown(() => tester.binding.setSurfaceSize(null));
  });

  testWidgets('landscape playback keeps controls and lyrics fixed while the '
      'cover turns into video', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: const MaterialApp(
          home: MusicPlayerScreen(
            title: 'Landscape video',
            debugLandscapeVideo: true,
            debugVideoFramesReady: true,
            debugVideoAspectRatio: 16 / 9,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final controls = find.byType(MusicPlaybackControls);
    final lyrics = find.byKey(const ValueKey('music-landscape-lyric-panel'));
    final stage = find.byKey(const ValueKey('music-cover-video-stage'));
    final controlsBefore = tester.getTopLeft(controls);
    final lyricsBefore = tester.getTopLeft(lyrics);
    final stageBefore = tester.getSize(stage);

    await _doubleTap(tester, stage);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.getTopLeft(controls), controlsBefore);
    expect(tester.getTopLeft(lyrics), lyricsBefore);
    expect(tester.getSize(stage).height, stageBefore.height);
    expect(tester.getSize(stage).width, greaterThan(stageBefore.width + 8));
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the next episode holds a poster until its picture arrives', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late StateSetter update;
    var itemId = 'episode-a';
    var framesReady = true;
    var aspect = 1.0;
    var isVideo = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MusicCoverVideoStage(
                  coverSize: 160,
                  maxFrameWidth: 420,
                  borderRadius: 8,
                  itemId: itemId,
                  isVideo: isVideo,
                  gestureEnabled: isVideo,
                  debugFramesReady: framesReady,
                  debugAspectRatio: aspect,
                  cover: const ColoredBox(color: Color(0xFF224466)),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final stage = find.byType(MusicCoverVideoStage);
    await _doubleTap(tester, stage);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    final height = tester.getSize(stage).height;
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsOneWidget,
    );

    update(() {
      itemId = 'episode-b';
      framesReady = false;
      aspect = 16 / 9;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(
      find.byKey(const ValueKey('music-cover-video-poster')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('music-cover-video-loading')),
      findsOneWidget,
    );
    expect(tester.getSize(stage).height, height);

    update(() => framesReady = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey('music-cover-video-poster')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('music-cover-video-loading')),
      findsNothing,
    );
    expect(tester.getSize(stage).height, height);
    expect(tester.getSize(stage).width, closeTo(160 * 16 / 9, 1));

    update(() {
      itemId = 'episode-c';
      isVideo = false;
      framesReady = false;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.getSize(stage).width, closeTo(160, 1));
    expect(tester.getSize(stage).height, height);
    expect(MediaPlaybackService().musicCoverOwnsVideoSurface, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a slow first frame keeps the cover and shows only a sheen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MusicCoverVideoStage(
              coverSize: 140,
              maxFrameWidth: 300,
              borderRadius: 6,
              itemId: 'pending',
              isVideo: true,
              gestureEnabled: true,
              cover: ColoredBox(color: Color(0xFF333333)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final stage = find.byType(MusicCoverVideoStage);
    final before = tester.getSize(stage);
    await _doubleTap(tester, stage);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('music-cover-video-sheen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('music-cover-video-surface')),
      findsNothing,
    );
    expect(tester.getSize(stage), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void _noop() {}

/// This Flutter version's [WidgetTester] has no doubleTap helper.
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}
