import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader('Inter')
          ..addFont(rootBundle.load('assets/fonts/Inter-ExtraBold.otf')))
        .load();
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
        .load();
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform mouse seek keeps the final line geometry stable', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 601));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1000, 751.25);
      addTearDown(tester.view.resetPhysicalSize);
      final position = ValueNotifier(Duration.zero);
      addTearDown(position.dispose);
      final subtitles = List.generate(
        20,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 5),
          endTime: Duration(seconds: index * 5 + 4),
          text: 'Lyric $index: A longer line that wraps on desktop.\n这是对应的中文翻译。',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                child: MusicLyricView(
                  subtitles: subtitles,
                  positionListenable: position,
                  onSeek: (value) => position.value = value,
                  splitSubtitleByLine: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final index in [1, 2, 1]) {
        final line = find.text('Lyric $index: A longer line that wraps on desktop.');
        final point = tester.getTopLeft(line) + const Offset(20, 10);
        await mouse.moveTo(point);
        await tester.pumpAndSettle();
        await mouse.down(point);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await mouse.up();
        await tester.pump();
        final samples = <double>[tester.getTopLeft(line).dy];
        for (var frame = 0; frame < 125; frame++) {
          await tester.pump(const Duration(milliseconds: 8));
          samples.add(tester.getTopLeft(line).dy);
        }
        expect(position.value, Duration(seconds: index * 5));
        final direction = (samples.last - samples.first).sign;
        expect((samples.last - samples.first).abs(), greaterThan(20));
        for (var sample = 1; sample < samples.length; sample++) {
          expect(
            (samples[sample] - samples[sample - 1]) * direction,
            greaterThanOrEqualTo(-0.05),
            reason: 'line $index frame $sample: $samples',
          );
          if (sample > 80) {
            expect((samples[sample] - samples[sample - 1]).abs(), lessThan(0.15));
          }
        }
      }
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 60));
    });
  }
}
