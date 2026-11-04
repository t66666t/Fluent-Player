import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final sample in [
      (size: const Size(568, 320), insets: EdgeInsets.zero),
      (size: const Size(844, 390), insets: EdgeInsets.zero),
      (size: const Size(960, 432), insets: EdgeInsets.zero),
      (size: const Size(1080, 480), insets: EdgeInsets.zero),
      (size: const Size(844, 390), insets: const EdgeInsets.only(bottom: 34)),
      (size: const Size(844, 390), insets: const EdgeInsets.only(top: 24)),
      (
        size: const Size(844, 390),
        insets: const EdgeInsets.only(left: 44, bottom: 21),
      ),
      (
        size: const Size(844, 390),
        insets: const EdgeInsets.only(right: 44, bottom: 21),
      ),
    ]) {
      testWidgets('phone balances visible controls at $platform / $sample', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await tester.binding.setSurfaceSize(sample.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var playPresses = 0;
        await tester.pumpWidget(
          _player(sample.size, sample.insets, onPlayPause: () => playPresses++),
        );
        await tester.pump(const Duration(milliseconds: 600));

        final close = tester.getRect(find.byIcon(Icons.close_rounded));
        final play = tester.getRect(find.byIcon(CupertinoIcons.play_fill));
        final bottomGap = sample.size.height - play.bottom;
        final safe = sample.insets.top > sample.insets.bottom
            ? sample.insets.top
            : sample.insets.bottom;
        // Compare visible icon boxes, not the differently sized hit targets.
        expect(close.top, closeTo(bottomGap, .1));
        expect(close.top - safe, inInclusiveRange(24.0, 28.0));

        final toolbar = tester.getRect(
          find.byKey(const ValueKey('music-landscape-toolbar')),
        );
        final artwork = tester.getRect(
          find.byKey(const ValueKey('music-cover-video-stage')),
        );
        final controls = tester.getRect(find.byType(MusicPlaybackControls));
        expect(artwork.top, greaterThanOrEqualTo(toolbar.bottom + 12 - .1));
        expect(artwork.bottom, lessThanOrEqualTo(controls.top + .1));
        expect(artwork.height, greaterThanOrEqualTo(48));
        expect(
          controls.bottom,
          closeTo(sample.size.height - sample.insets.bottom, .1),
        );
        await tester.tap(find.byKey(const ValueKey('music-play-pause-button')));
        expect(playPresses, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  testWidgets('short phone keeps transport visible while metadata scrolls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = Size(568, 320);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _player(
        size,
        const EdgeInsets.only(left: 44, bottom: 34),
        textScale: 1.8,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final play = find.byKey(const ValueKey('music-play-pause-button'));
    final before = tester.getRect(play);
    final scroll = find.ancestor(
      of: find.byType(MusicAlbumCover),
      matching: find.byType(SingleChildScrollView),
    );
    final contentTop = tester.getTopLeft(find.byType(MusicAlbumCover)).dy;
    await tester.drag(scroll, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(tester.getRect(play), before);
    expect(
      tester.getTopLeft(find.byType(MusicAlbumCover)).dy,
      lessThan(contentTop),
    );
    expect(before.bottom, lessThanOrEqualTo(size.height - 34));
    expect(
      tester.getRect(find.byIcon(Icons.close_rounded)).top,
      closeTo(
        size.height -
            tester.getRect(find.byIcon(CupertinoIcons.play_fill)).bottom,
        .1,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone transport stays docked across cover flips and rotation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = Size(960, 432);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_player(size, EdgeInsets.zero, video: true));
    await tester.pump(const Duration(milliseconds: 600));
    final play = find.byKey(const ValueKey('music-play-pause-button'));
    final before = tester.getRect(play);
    final stage = find.byKey(const ValueKey('music-cover-video-stage'));
    final artworkHeight = tester.getSize(stage).height;
    await tester.tap(stage);
    await tester.pump(const Duration(milliseconds: 75));
    await tester.tap(stage);
    await tester.pumpAndSettle();
    expect(tester.getRect(play), before);
    expect(tester.getSize(stage).height, artworkHeight);
    expect(tester.getSize(stage).width, greaterThan(artworkHeight));

    const portrait = Size(432, 960);
    await tester.binding.setSurfaceSize(portrait);
    await tester.pumpWidget(_player(portrait, EdgeInsets.zero));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester
          .widget<MusicPlaybackControls>(find.byType(MusicPlaybackControls))
          .bottomIconInset,
      isNull,
    );
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(_player(size, EdgeInsets.zero));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(play), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    MediaPlaybackService().debugClearMusicCoverVideoSurface();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('large screens preserve natural controls at $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const size = Size(1180, 820);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_player(size, EdgeInsets.zero));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester
            .widget<MusicPlaybackControls>(find.byType(MusicPlaybackControls))
            .bottomIconInset,
        isNull,
      );
      expect(
        tester.widget<MusicAlbumCover>(find.byType(MusicAlbumCover)).maxHeight,
        isNull,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('music-landscape-toolbar')))
            .dy,
        16,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final size in [const Size(844, 390), const Size(568, 320)]) {
    testWidgets('landscape artwork uses spare height at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_player(size, EdgeInsets.zero));
      await tester.pump(const Duration(milliseconds: 600));
      final stage = find.byKey(const ValueKey('music-cover-video-stage'));
      final artwork = tester.getRect(stage);
      final controls = tester.getRect(find.byType(MusicPlaybackControls));
      expect(artwork.height, greaterThan((size.height - 72) * .30));
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('music-landscape-toolbar')),
      );
      expect(artwork.top, greaterThanOrEqualTo(toolbar.bottom + 12 - .1));
      expect(controls.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final insets in [
      const EdgeInsets.only(top: 24, bottom: 20),
      const EdgeInsets.only(left: 32, top: 12),
    ]) {
      testWidgets('tablet balances screen corner at $platform / $insets', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const size = Size(1180, 820);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_player(size, insets));
        await tester.pump(const Duration(milliseconds: 600));
        final corner = tester.getTopLeft(
          find.byKey(const ValueKey('music-landscape-toolbar')),
        );
        expect(corner.dx, corner.dy);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}

Widget _player(
  Size size,
  EdgeInsets insets, {
  double textScale = 1,
  VoidCallback? onPlayPause,
  bool video = false,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(
      value: SettingsService()..resetForTest(),
    ),
    ChangeNotifierProvider<MediaPlaybackService>.value(
      value: MediaPlaybackService(),
    ),
  ],
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: size,
        padding: insets,
        viewPadding: insets,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: MusicPlayerScreen(
      title: 'A long landscape title with enough text to fill both lines',
      onPlayPause: onPlayPause,
      debugLandscapeVideo: video,
      debugVideoFramesReady: video,
    ),
  ),
);
