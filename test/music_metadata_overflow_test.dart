import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';
import 'package:video_player_app/widgets/music_overflow_text.dart';

void main() {
  Widget caption(
    String text, {
    double width = 220,
    bool reduceMotion = false,
    int lines = 1,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: MusicOverflowText(
              text: text,
              style: const TextStyle(fontSize: 16),
              maxLines: lines,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('metadata wraps in available space before scrolling', (
    tester,
  ) async {
    await tester.pumpWidget(
      caption('A title that fits on two lines', width: 300, lines: 2),
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    final text = tester.widget<Text>(
      find.text('A title that fits on two lines'),
    );
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overflowing metadata scrolls slowly and resets for a new episode',
    (tester) async {
      await tester.pumpWidget(
        caption(List.filled(12, 'Long metadata ').join()),
      );
      final scrolling = find.byType(Scrollable);
      expect(scrolling, findsOneWidget);
      final state = tester.state<ScrollableState>(scrolling);
      expect(state.position.pixels, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(state.position.pixels, closeTo(24, 2));
      await tester.pumpWidget(caption('Next'));
      expect(find.byType(Scrollable), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion leaves full metadata available by manual scroll',
    (tester) async {
      await tester.pumpWidget(
        caption(List.filled(12, 'Long metadata ').join(), reduceMotion: true),
      );
      final scrolling = find.byType(Scrollable);
      final state = tester.state<ScrollableState>(scrolling);
      await tester.pump(const Duration(seconds: 4));
      expect(state.position.pixels, 0);
      await tester.drag(scrolling, const Offset(-80, 0));
      await tester.pump();
      expect(state.position.pixels, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('horizontal player gives metadata more width than the artwork', (
    tester,
  ) async {
    for (final size in const [Size(844, 390), Size(1440, 900)]) {
      await tester.binding.setSurfaceSize(size);
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
          child: const MaterialApp(
            home: MusicPlayerScreen(
              followCurrentSession: false,
              title: 'An episode title with enough room to read',
              artist: 'The channel and author',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final artwork = tester.widget<MusicAlbumCover>(
        find.byType(MusicAlbumCover),
      );
      expect(artwork.infoWidth!, greaterThan(artwork.coverSize! + 80));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.binding.setSurfaceSize(null);
  });
}
