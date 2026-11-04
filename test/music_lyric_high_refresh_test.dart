import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_frame_coordinator.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

class _CountingClock extends ValueNotifier<Duration> {
  _CountingClock(super.value);
  final listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

List<SubtitleItem> _cues(int count, {int offset = 0}) =>
    List.generate(count, (i) {
      final index = i + offset;
      final text = 'Timed lyric $index';
      return SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: index * 5 + 4),
        text: text,
        lyricTranslation: '双语歌词 $index',
        timedSpans: [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: text.length,
            startTime: Duration(seconds: index * 5),
            endTime: Duration(seconds: index * 5 + 4),
          ),
        ],
      );
    });

RenderCustomPaint _ink(WidgetTester tester) =>
    tester.renderObject<RenderCustomPaint>(
      find.descendant(
        of: find.byType(MusicTimedLyricText),
        matching: find.byType(CustomPaint),
      ),
    );

void main() {
  test('cached row dispatch is bounded to the visible range and prefetch', () {
    final source = ValueNotifier(Duration.zero);
    addTearDown(source.dispose);
    final frames = MusicLyricFrameCoordinator(source);
    final counts = List.filled(100, 0);
    final rows = [for (var i = 0; i < 100; i++) frames.register(i)];
    addTearDown(() {
      for (final row in rows) {
        row.dispose();
      }
    });
    for (var i = 0; i < rows.length; i++) {
      rows[i].addListener(() => counts[i]++);
    }
    frames.setVisibleRange(40, 42);
    for (var frame = 0; frame < 120; frame++) {
      source.value = Duration(microseconds: frame * 8333);
      frames.publishPosition();
    }
    expect(frames.activeRows, 5);
    expect(counts[39], 120);
    expect(counts[43], 120);
    expect(counts[0], 0);
    expect(counts[99], 0);
    frames.setVisibleRange(98, 99);
    expect(counts[99], 1, reason: 'resume samples the latest media position');
    expect(rows[99].value, source.value);
  });

  testWidgets('plain text does not subscribe to the playback clock', (
    tester,
  ) async {
    final clock = _CountingClock(Duration.zero);
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MusicTimedLyricText(
          text: 'Plain lyric',
          spans: const [],
          position: clock,
          style: const TextStyle(fontSize: 30),
        ),
      ),
    );
    expect(clock.listeners, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'distant crossfade waits for the new primary range before suspending rows',
    () {
      final source = ValueNotifier(Duration.zero);
      addTearDown(source.dispose);
      final frames = MusicLyricFrameCoordinator(source)..setVisibleRange(0, 2);
      final rows = [for (var i = 0; i < 100; i++) frames.register(i)];
      addTearDown(() {
        for (final row in rows) {
          row.dispose();
        }
      });
      frames.setLocating(true);
      expect(frames.activeRows, 100);
      frames.setLocating(false);
      expect(rows[80].activity.value, isTrue);
      frames.setVisibleRange(79, 81);
      expect(rows[80].activity.value, isTrue);
      expect(rows[0].activity.value, isFalse);
      expect(frames.activeRows, 5);
    },
  );

  testWidgets('the complete region has one upstream playback listener', (
    tester,
  ) async {
    final clock = _CountingClock(const Duration(seconds: 50));
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: MusicLyricRegion(
            mediaId: 'song',
            subtitles: _cues(100),
            secondarySubtitles: const [],
            splitSubtitleByLine: false,
            preference: MusicLyricTrackDisplayMode.both,
            onPreferenceChanged: (_) {},
            positionListenable: clock,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(clock.listeners.length, 1);
    final view = tester.widget<MusicLyricView>(find.byType(MusicLyricView));
    expect(view.projection, isNotNull);
    final rowClocks = tester
        .widgetList<MusicLyricRowFrameScope>(
          find.byType(MusicLyricRowFrameScope, skipOffstage: false),
        )
        .map((scope) => scope.clock)
        .toList();
    expect(rowClocks.where((row) => !row.activity.value), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(clock.listeners, isEmpty);
  });

  testWidgets('cached word ink resumes at the current time after a seek', (
    tester,
  ) async {
    final clock = ValueNotifier(Duration.zero);
    addTearDown(clock.dispose);
    final frames = MusicLyricFrameCoordinator(clock)..setVisibleRange(0, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: MusicLyricRowFrame(
          coordinator: frames,
          index: 50,
          child: MusicTimedLyricText(
            text: 'Hello',
            spans: const [
              SubtitleTimedSpan(
                textStart: 0,
                textEnd: 5,
                startTime: Duration(seconds: 1),
                endTime: Duration(seconds: 4),
              ),
            ],
            position: clock,
            style: const TextStyle(fontSize: 32, color: Colors.white),
          ),
        ),
      ),
    );
    clock.value = const Duration(seconds: 3);
    frames.publishPosition();
    expect(_ink(tester).debugNeedsPaint, isFalse);
    frames.setVisibleRange(49, 51);
    expect(_ink(tester).debugNeedsPaint, isTrue);
    await tester.pump();
    expect(_ink(tester).debugNeedsPaint, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unchanged mobile focus reuses its image filter object', (
    tester,
  ) async {
    final motion = MusicLyricFollowMotion();
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: MusicLyricDepth(
          active: false,
          distance: 8,
          browsing: false,
          rasterFocus: true,
          motion: motion,
          child: const Text('Distant lyric'),
        ),
      ),
    );
    final filter = tester.renderObject(
      find.byWidgetPredicate((widget) => widget is ImageFiltered),
    );
    final layer = filter.debugLayer! as ImageFilterLayer;
    final kernel = layer.imageFilter;
    for (var frame = 0; frame < 20; frame++) {
      motion.advance(2);
      await tester.pump(const Duration(microseconds: 8333));
      expect(layer.imageFilter, same(kernel));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('colour changes reuse the shaped glyph atlas', (tester) async {
    final colour = ValueNotifier(Colors.white.withValues(alpha: 0.8));
    addTearDown(colour.dispose);
    var images = 0;
    final previous = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      images++;
      previous?.call(image);
    };
    addTearDown(() => ui.Image.onCreate = previous);
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: ValueListenableBuilder<Color>(
              valueListenable: colour,
              builder: (context, color, _) => MusicTimedLyricText(
                text: 'Hello world',
                spans: const [
                  SubtitleTimedSpan(
                    textStart: 0,
                    textEnd: 11,
                    startTime: Duration(seconds: 1),
                    endTime: Duration(seconds: 5),
                  ),
                ],
                dimUnplayed: false,
                style: TextStyle(fontSize: 32, color: color),
              ),
            ),
          ),
        ),
      ),
    );
    Future<int> brightness() async => (await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      var sum = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        sum += bytes[i];
      }
      image.dispose();
      return sum;
    }))!;
    final before = await brightness();
    final allocations = images;
    colour.value = Colors.white.withValues(alpha: 0.4);
    await tester.pump();
    expect(
      images,
      allocations,
      reason: 'paint colour must not recreate glyphs',
    );
    expect(await brightness() / before, closeTo(0.5, 0.02));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final hz in [90, 120, 144]) {
    final step = Duration(microseconds: (1000000 / hz).round());
    testWidgets('$hz Hz follow handoff preserves the painted position', (
      tester,
    ) async {
      final motion = MusicLyricFollowMotion()..enabled = true;
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: MusicLyricFollow(
            motion: motion,
            distance: 2,
            child: const Text('Follow handoff'),
          ),
        ),
      );
      final line = find.text('Follow handoff');
      final start = tester.getTopLeft(line).dy;
      for (var frame = 0; frame < 20; frame++) {
        motion.advance(3);
        await tester.pump(step);
      }
      final before = tester.getTopLeft(line).dy;
      expect(before - start, greaterThan(3));
      motion.enabled = false;
      await tester.pump();
      expect(tester.getTopLeft(line).dy, closeTo(before, 0.01));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(line).dy, closeTo(start, 0.05));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$hz Hz mobile motion does not rebuild animation widgets', (
      tester,
    ) async {
      final active = ValueNotifier(false);
      final motion = MusicLyricFollowMotion()..enabled = true;
      addTearDown(active.dispose);
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, value, _) => MusicLyricFollow(
              motion: motion,
              distance: 1,
              child: MusicLyricDepth(
                active: value,
                distance: 1,
                browsing: false,
                rasterFocus: true,
                motion: motion,
                child: const Text('Render-only motion'),
              ),
            ),
          ),
        ),
      );
      active.value = true;
      await tester.pump();
      final subtree = <Element>{};
      void visit(Element element) {
        subtree.add(element);
        element.visitChildren(visit);
      }

      visit(tester.element(find.byType(MusicLyricFollow)));
      final previous = debugOnRebuildDirtyWidget;
      var rebuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (subtree.contains(element)) rebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      final line = find.text('Render-only motion');
      final before = tester.getTopLeft(line).dy;
      for (var frame = 0; frame < 30; frame++) {
        motion.advance(2);
        await tester.pump(step);
      }
      expect((tester.getTopLeft(line).dy - before).abs(), greaterThan(1));
      expect(rebuilds, 0);
      debugOnRebuildDirtyWidget = previous;
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'stream append refreshes lyrics without rebuilding player layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final playback = MediaPlaybackService.forTesting();
      final settings = SettingsService()..resetForTest();
      addTearDown(playback.dispose);
      final buffer = SubtitleCueBuffer()..addAll(_cues(20));
      playback.setSubtitleState(
        paths: [],
        primary: buffer.snapshot,
        secondary: [],
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: const MusicPlayerScreen(title: 'Stream layout'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final layout = tester.widget(
        find.byKey(const ValueKey('music-portrait-header')),
      );
      final lyric = tester.state(find.byType(MusicLyricView));
      buffer.addAll(_cues(5, offset: 20));
      playback.setSubtitleState(
        paths: [],
        primary: buffer.snapshot,
        secondary: [],
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget(find.byKey(const ValueKey('music-portrait-header'))),
        same(layout),
      );
      expect(tester.state(find.byType(MusicLyricView)), same(lyric));
      expect(
        tester
            .widget<MusicLyricView>(find.byType(MusicLyricView))
            .subtitles
            .length,
        25,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
