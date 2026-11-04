import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mini progress slider builds above the navigator overlay', (
    tester,
  ) async {
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(primary: Colors.blue),
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(isVisible: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);

    final theme = tester.widget<SliderTheme>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(SliderTheme))
          .first,
    );
    expect(theme.data.trackHeight, 2);
    expect(theme.data.trackShape, isA<RoundedRectSliderTrackShape>());

    final slider = tester.renderObject<RenderBox>(find.byType(Slider));
    expect(slider.size.height, lessThanOrEqualTo(27));
  });

  testWidgets('mini card tap does not start a splash that can resume later', (
    tester,
  ) async {
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(isVisible: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final inkWell = tester.widget<InkWell>(find.byType(InkWell));
    expect(inkWell.splashFactory, NoSplash.splashFactory);
    expect(inkWell.highlightColor, Colors.transparent);
    expect(inkWell.splashColor, Colors.transparent);
    expect(inkWell.hoverColor, Colors.transparent);
    expect(inkWell.overlayColor?.resolve(<WidgetState>{}), Colors.transparent);
  });
}
