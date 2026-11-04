import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/music_play_pause_button.dart';

void main() {
  testWidgets('loading ignores blips, rotates slowly, and suppresses repeats', (
    tester,
  ) async {
    var loading = false;
    var playing = false;
    var taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MusicPlayPauseButton(
                  isPlaying: playing,
                  isLoading: loading,
                  iconSize: 42,
                  minimumSize: 55,
                  onPressed: () => taps++,
                );
              },
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('music-play-pause-button'));
    final spinner = find.byKey(const ValueKey('music-playback-loading'));
    final bounds = tester.getRect(button);
    await tester.tap(button);
    expect(taps, 1);
    for (var index = 0; index < 3; index++) {
      update(() => loading = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(spinner, findsNothing);
      await tester.tap(button);
      expect(taps, 1, reason: 'Do not restart an in-flight open request');
      update(() => loading = false);
      await tester.pump(const Duration(milliseconds: 150));
      expect(spinner, findsNothing);
    }
    update(() => loading = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 160));
    expect(spinner, findsOneWidget);
    expect(tester.getRect(button), bounds);
    final turns = tester.widget<RotationTransition>(spinner).turns;
    final previous = turns.value;
    await tester.pump(const Duration(milliseconds: 700));
    expect(turns.value - previous, closeTo(.25, .02));
    update(() {
      loading = false;
      playing = true;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(spinner, findsNothing);
    expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);
    expect(tester.getRect(button), bounds);
    // A second stall shortly afterwards must not flash another ring.
    update(() => loading = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(spinner, findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 180));
    expect(spinner, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows a static ring and cancels pending timers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Center(
            child: MusicPlayPauseButton(
              isPlaying: false,
              isLoading: true,
              iconSize: 42,
              minimumSize: 55,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final spinner = find.byKey(const ValueKey('music-playback-loading'));
    final before = tester.widget<RotationTransition>(spinner).turns.value;
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<RotationTransition>(spinner).turns.value, before);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
