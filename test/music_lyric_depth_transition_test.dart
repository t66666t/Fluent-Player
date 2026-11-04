import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform keeps the blur layer through focus, reversals and settling',
      (tester) async {
        final selected = ValueNotifier(false);
        addTearDown(selected.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: selected,
                child: const Text(
                  'Smooth lyric 清晰歌词',
                  style: TextStyle(fontSize: 40),
                ),
                builder: (context, active, child) => MusicLyricDepth(
                  active: active,
                  distance: 1,
                  browsing: false,
                  child: child!,
                ),
              ),
            ),
          ),
        );
        final render = tester.renderObject(find.byType(ImageFiltered));
        final layer = render.debugLayer;
        expect(layer, isA<ImageFilterLayer>());
        // Clearing a nearly-zero blur must not remove the compositing boundary
        // and rerasterize the text in a different layer at the end of the motion.
        for (final active in [true, false, true]) {
          selected.value = active;
          await tester.pump();
          for (var frame = 0; frame < 48; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              render.debugLayer,
              same(layer),
              reason: 'frame $frame, active=$active',
            );
            expect(
              tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
              isTrue,
            );
          }
        }
        selected.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        selected.value = true;
        await tester.pump();
        await tester.pumpAndSettle();
        expect(render.debugLayer, same(layer));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$platform auto-follow keeps the incoming lyric filter attached until clear',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(700, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        final cues = List.generate(
          10,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 4),
            text: 'Lyric $i',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: MusicLyricView(subtitles: cues, positionListenable: clock),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final depth = find.ancestor(
          of: find.text('Lyric 1'),
          matching: find.byType(MusicLyricDepth),
        );
        final filter = find.descendant(
          of: depth,
          matching: find.byWidgetPredicate((widget) => widget is ImageFiltered),
        );
        final render = tester.renderObject(filter);
        final layer = render.debugLayer;
        // The gap also focuses the upcoming row before its actual singing starts.
        clock.value = const Duration(milliseconds: 4100);
        await tester.pump();
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.renderObject(filter), same(render));
          expect(
            render.debugLayer,
            same(layer),
            reason: 'incoming lyric, frame $frame',
          );
        }
        clock.value = const Duration(seconds: 5);
        await tester.pumpAndSettle();
        expect(render.debugLayer, same(layer));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'reduced motion keeps focused lyrics sharp without an unnecessary filter layer',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: MusicLyricDepth(
              active: true,
              distance: 0,
              browsing: false,
              child: Text('Clear'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );
    },
  );
}
