import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

class _CountingClock extends ValueNotifier<Duration> {
  _CountingClock() : super(Duration.zero);
  int reads = 0;

  @override
  Duration get value {
    reads++;
    return super.value;
  }
}

void main() {
  testWidgets('covered transcript suspends visual clock work and catches up', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'autoScrollSubtitles': true});
    await (SettingsService()..resetForTest()).init();
    final clock = _CountingClock();
    addTearDown(clock.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: SubtitleSidebar(
            subtitles: List.generate(
              10,
              (i) => SubtitleItem(
                index: i,
                startTime: Duration(seconds: i * 5),
                endTime: Duration(seconds: i * 5 + 5),
                text: 'subtitle $i',
              ),
            ),
            positionListenable: clock,
            isCompact: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('music page')),
    );
    await tester.pumpAndSettle();
    clock.reads = 0;
    for (var tick = 1; tick <= 144; tick++) {
      clock.value = Duration(milliseconds: 20000 + tick * 7);
      await tester.pump(const Duration(microseconds: 6944));
    }
    expect(clock.reads, 0, reason: 'an opaque route covers the transcript');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(clock.reads, greaterThan(0));
    expect(find.text('subtitle 4', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
