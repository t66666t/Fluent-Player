import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  testWidgets('portrait controls only hide while timed subtitles are available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final playback = MediaPlaybackService.forTesting();
    final settings = SettingsService()..resetForTest();
    settings.musicPortraitControlsAutoHide = true;
    var followSession = true;
    var loading = false;
    late StateSetter update;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MusicPlayerScreen(
                title: 'Controls',
                followCurrentSession: followSession,
                isLoading: loading,
              );
            },
          ),
        ),
      ),
    );
    final controls = find.byKey(
      const ValueKey('music-portrait-controls-overlay'),
    );
    void expectVisible(bool visible) {
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .descendant(
                    of: controls,
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        !visible,
      );
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .descendant(
                    of: controls,
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value,
        visible ? 1 : 0,
      );
    }

    Future<void> idle() async {
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
    }

    SubtitleItem cue(String text) => SubtitleItem(
      index: 0,
      startTime: Duration.zero,
      endTime: const Duration(minutes: 1),
      text: text,
    );

    await idle();
    expectVisible(true);
    playback.setSubtitleState(paths: [], primary: [cue('   ')], secondary: []);
    await idle();
    expectVisible(true);

    playback.setSubtitleState(paths: [], primary: [cue('主字幕')], secondary: []);
    await idle();
    expectVisible(false);
    update(() => loading = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await idle();
    expectVisible(true);
    expect(
      find.byKey(const ValueKey('music-playback-loading')),
      findsOneWidget,
    );
    update(() => loading = false);
    await tester.pump();
    await idle();
    expectVisible(false);
    // Removing the last track restores controls without needing a tap.
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectVisible(true);
    await idle();
    expectVisible(true);

    playback.setSubtitleState(paths: [], primary: [], secondary: [cue('副字幕')]);
    await idle();
    expectVisible(false);
    // A pending episode must not inherit the previous episode's hidden controls.
    update(() => followSession = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectVisible(true);
    await idle();
    expectVisible(true);
    await tester.pumpWidget(const SizedBox.shrink());
    playback.dispose();
  });
}
