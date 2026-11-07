import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';

class _Clock extends ValueNotifier<Duration> {
  _Clock(super.value);

  bool get listening => hasListeners;
}

Widget _controls(
  ValueNotifier<Duration> position, {
  Duration duration = const Duration(seconds: 90),
  CustomPainter? background,
}) => MaterialApp(
  home: Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (background != null) CustomPaint(painter: background),
        Center(
          child: SizedBox(
            width: 360,
            child: MusicPlaybackControls(
              positionListenable: position,
              totalDuration: duration,
              onProgressChanged: (_) {},
              onSubtitleManagement: () {},
            ),
          ),
        ),
      ],
    ),
  ),
);

Text _time(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key)));

class _CountPaints extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_CountPaints oldDelegate) => false;
}

void main() {
  testWidgets(
    '144 Hz progress leaves timestamp widgets and backdrop retained',
    (tester) async {
      final clock = ValueNotifier(const Duration(milliseconds: 1100));
      addTearDown(clock.dispose);
      final background = _CountPaints();
      await tester.pumpWidget(_controls(clock, background: background));
      await tester.pumpAndSettle();
      final current = _time(tester, 'music-current-time');
      final remaining = _time(tester, 'music-remaining-time');
      final chip = tester.widget(
        find.byKey(const ValueKey('music-landscape-subtitle-management')),
      );
      final paints = background.paints;
      for (var frame = 1; frame <= 100; frame++) {
        clock.value = Duration(microseconds: 1100000 + frame * 6944);
        await tester.pump(const Duration(microseconds: 6944));
        expect(_time(tester, 'music-current-time'), same(current));
        expect(_time(tester, 'music-remaining-time'), same(remaining));
        expect(
          tester.widget(
            find.byKey(const ValueKey('music-landscape-subtitle-management')),
          ),
          same(chip),
        );
        expect(
          tester
              .widget<Slider>(
                find.byKey(const ValueKey('music-progress-slider')),
              )
              .value,
          clock.value.inMilliseconds / 90000,
        );
      }
      expect(background.paints, paints);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'remaining seconds have their own boundary and seeks stay immediate',
    (tester) async {
      final clock = ValueNotifier(const Duration(milliseconds: 1100));
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        _controls(clock, duration: const Duration(milliseconds: 10500)),
      );
      await tester.pumpAndSettle();
      expect(_time(tester, 'music-current-time').data, '00:01');
      expect(_time(tester, 'music-remaining-time').data, '00:10');
      await tester.tap(find.byKey(const ValueKey('music-remaining-time')));
      await tester.pump();
      expect(_time(tester, 'music-remaining-time').data, '-00:09');
      clock.value = const Duration(milliseconds: 1600);
      await tester.pump();
      expect(_time(tester, 'music-current-time').data, '00:01');
      expect(_time(tester, 'music-remaining-time').data, '-00:08');
      clock.value = const Duration(milliseconds: 8700);
      await tester.pump();
      expect(_time(tester, 'music-current-time').data, '00:08');
      expect(_time(tester, 'music-remaining-time').data, '-00:01');
      clock.value = const Duration(seconds: 12);
      await tester.pump();
      expect(_time(tester, 'music-remaining-time').data, '-00:00');
      clock.value = const Duration(milliseconds: 1100);
      await tester.pump();
      expect(_time(tester, 'music-current-time').data, '00:01');
      expect(_time(tester, 'music-remaining-time').data, '-00:09');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'duration and clock replacement refresh labels and detach old clock',
    (tester) async {
      final oldClock = _Clock(const Duration(seconds: 2));
      final nextClock = _Clock(const Duration(seconds: 3661));
      addTearDown(oldClock.dispose);
      addTearDown(nextClock.dispose);
      await tester.pumpWidget(_controls(oldClock));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _controls(nextClock, duration: const Duration(seconds: 7200)),
      );
      await tester.pump();
      expect(oldClock.listening, isFalse);
      expect(_time(tester, 'music-current-time').data, '1:01:01');
      expect(_time(tester, 'music-remaining-time').data, '2:00:00');
      oldClock.value = const Duration(seconds: 20);
      await tester.pump();
      expect(_time(tester, 'music-current-time').data, '1:01:01');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(nextClock.listening, isFalse);
    },
  );

  testWidgets('right time starts as the duration and remembers the tap', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    addTearDown(settings.resetForTest);
    await settings.init();
    await settings.updateMusicProgressShowsRemaining(true);
    final clock = ValueNotifier(const Duration(milliseconds: 1100));
    addTearDown(clock.dispose);

    Future<void> mount() {
      return tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: _controls(
            clock,
            duration: const Duration(milliseconds: 10500),
          ),
        ),
      );
    }

    await mount();
    await tester.pumpAndSettle();
    final slider = tester.getRect(
      find.byKey(const ValueKey('music-progress-slider')),
    );
    expect(_time(tester, 'music-remaining-time').data, '-00:09');
    expect(
      tester.getRect(find.byKey(const ValueKey('music-remaining-time'))).right,
      closeTo(slider.right, 0.5),
    );

    await tester.tap(find.byKey(const ValueKey('music-remaining-time')));
    await tester.pump();
    expect(settings.musicProgressShowsRemaining, isFalse);
    expect(_time(tester, 'music-remaining-time').data, '00:10');
    expect(
      tester.getRect(find.byKey(const ValueKey('music-remaining-time'))).right,
      closeTo(slider.right, 0.5),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    await tester.pump();
    expect(_time(tester, 'music-remaining-time').data, '00:10');

    settings.resetForTest();
    await settings.init();
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    await tester.pump();
    expect(_time(tester, 'music-remaining-time').data, '00:10');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
