import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform drag during lyric animation never seeks', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: MusicLyricView(
              subtitles: _lyrics,
              onSeek: seeks.add,
              applyEdgeFade: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Lyric 2'));
      await tester.pump(const Duration(milliseconds: 80));
      final drag = await tester.startGesture(
        tester.getCenter(find.text('Lyric 4')),
      );
      await drag.moveBy(const Offset(0, -70));
      await tester.pump(const Duration(milliseconds: 30));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 150));
      expect(seeks, [const Duration(seconds: 10)]);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$platform small swipes, cancelled touches and multi-touch do not seek',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final seeks = <Duration>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: MusicLyricView(
                subtitles: _lyrics,
                onSeek: seeks.add,
                applyEdgeFade: false,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final point = tester.getCenter(find.text('Lyric 2'));
        final smallSwipe = await tester.startGesture(point);
        await smallSwipe.moveBy(const Offset(0, 10));
        await smallSwipe.moveBy(const Offset(0, -10));
        await smallSwipe.up();
        final cancelled = await tester.startGesture(point);
        await cancelled.cancel();
        final first = await tester.startGesture(point);
        final second = await tester.startGesture(point + const Offset(0, 5));
        await second.up();
        await first.up();
        await tester.pump(const Duration(milliseconds: 150));
        expect(seeks, isEmpty);
        await tester.tap(find.text('Lyric 2'));
        await tester.pump();
        expect(seeks, [const Duration(seconds: 10)]);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform lyric positioning reaches its anchor', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 601));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: MusicLyricView(
              subtitles: _lyrics,
              onSeek: seeks.add,
              applyEdgeFade: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lyric 4'));
      await tester.pumpAndSettle();
      expect(seeks, [const Duration(seconds: 20)]);
      expect(
        tester.getTopLeft(find.text('Lyric 4')).dy,
        closeTo(601 * 0.30, 1.0),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Windows wrapped lyric finishes without an anchor correction', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(650, 601));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    const text =
        'A long lyric that wraps across multiple lines in the viewport '
        'and exposes any scale or layout shift when positioning finishes';
    final lyrics = [
      ..._lyrics.take(4),
      SubtitleItem(
        index: 4,
        startTime: const Duration(seconds: 20),
        endTime: const Duration(seconds: 24),
        text: text,
      ),
      ..._lyrics.skip(5),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: MusicLyricView(
            subtitles: lyrics,
            positionListenable: position,
            onSeek: (value) => position.value = value,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pump();
    final samples = <double>[];
    for (var frame = 0; frame < 70; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (frame >= 45) samples.add(tester.getTopLeft(find.text(text)).dy);
    }
    expect(samples.last, closeTo(601 * 0.30, 0.1));
    for (var i = 1; i < samples.length; i++) {
      expect((samples[i] - samples[i - 1]).abs(), lessThan(0.15));
    }
    // A press on the already positioned row must keep its glyphs at the same
    // leading edge throughout feedback, including while the pointer is held.
    final settledTop = tester.getTopLeft(find.text(text)).dy;
    final press = await tester.startGesture(
      tester.getTopLeft(find.text(text)) + const Offset(20, 20),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 105));
    expect(tester.getTopLeft(find.text(text)).dy, closeTo(settledTop, 0.1));
    await press.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text(text)).dy, closeTo(settledTop, 0.1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _lyrics = List.generate(
  10,
  (index) => SubtitleItem(
    index: index,
    startTime: Duration(seconds: index * 5),
    endTime: Duration(seconds: index * 5 + 4),
    text: 'Lyric $index',
  ),
);
