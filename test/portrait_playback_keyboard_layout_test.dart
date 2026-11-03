import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';
import 'package:video_player_app/widgets/portrait_playback_layout.dart';

void main() {
  const videoKey = ValueKey('video');
  const controlsKey = ValueKey('controls');
  const composerKey = ValueKey('composer');
  const panelKey = ValueKey('panel');

  testWidgets(
    'IME frames only change geometry, retaining video, controls and page builds',
    (tester) async {
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);
      var pageBuilds = 0;
      var videoBuilds = 0;
      var controlsBuilds = 0;
      var controlPaints = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AiPlaybackKeyboardBoundary(
            enabled: true,
            child: Builder(
              builder: (context) {
                pageBuilds++;
                // The real page and descendants also read the full media data.
                final media = MediaQuery.of(context);
                expect(media.viewInsets.bottom, 0);
                expect(media.padding.bottom, 20);
                return Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: SafeArea(
                    maintainBottomViewPadding: true,
                    child: AiKeyboardViewport(
                      reservedBottomInset: media.viewPadding.bottom,
                      child: PortraitPlaybackLayout(
                        videoHeightFraction: .32,
                        video: Builder(
                          builder: (context) {
                            videoBuilds++;
                            MediaQuery.of(context);
                            return const AspectRatio(
                              aspectRatio: 16 / 9,
                              child: ColoredBox(
                                key: videoKey,
                                color: Colors.black,
                              ),
                            );
                          },
                        ),
                        controls: Builder(
                          builder: (context) {
                            controlsBuilds++;
                            MediaQuery.of(context);
                            return SizedBox(
                              key: controlsKey,
                              height: 80,
                              width: double.infinity,
                              child: CustomPaint(
                                painter: _PaintCounter(() => controlPaints++),
                              ),
                            );
                          },
                        ),
                        panel: const Column(
                          key: panelKey,
                          children: [
                            Expanded(child: SizedBox.expand()),
                            SizedBox(
                              key: composerKey,
                              height: 44,
                              width: double.infinity,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final initialBuilds = (pageBuilds, videoBuilds, controlsBuilds);
      final initialPaints = controlPaints;
      final video = tester.element(find.byKey(videoKey));
      final controls = tester.element(find.byKey(controlsKey));
      for (final inset in [
        120.0,
        240.0,
        320.0,
        400.0,
        460.0,
        460.25,
        500.0,
        460.0,
        320.0,
        400.0,
        240.0,
        120.0,
        0.0,
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        tester.view.padding = FakeViewPadding(
          top: 24,
          bottom: inset > 0 ? 0 : 20,
        );
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(840 - (inset > 20 ? inset : 20), .01),
          reason: 'composer must follow native inset=$inset in this frame',
        );
        expect(tester.getSize(find.byKey(videoKey)).height, greaterThan(0));
        expect(tester.getSize(find.byKey(controlsKey)).height, 80);
        expect(
          _screenRect(tester, find.byKey(controlsKey)).bottom,
          closeTo(tester.getTopLeft(find.byKey(panelKey)).dy, .01),
          reason: 'the entire scaled controls block must fit above the panel',
        );
        expect(tester.element(find.byKey(videoKey)), same(video));
        expect(tester.element(find.byKey(controlsKey)), same(controls));
        expect((pageBuilds, videoBuilds, controlsBuilds), initialBuilds);
        expect(controlPaints, initialPaints);
        expect(tester.takeException(), isNull);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final fraction in <double?>[.32, .42, .58, null]) {
    for (final size in [const Size(390, 844), const Size(360, 640)]) {
      for (final aspectRatio in [16 / 9, 9 / 16]) {
        final scale = size.height < 700 ? 1.6 : 1.0;
        testWidgets(
          'whole controls scale and remain interactive during IME '
          'fraction=$fraction size=$size textScale=$scale ratio=$aspectRatio',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            tester.view.viewPadding = const FakeViewPadding(
              top: 24,
              bottom: 20,
            );
            tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
            addTearDown(tester.view.reset);
            final draft = TextEditingController(text: '保留的对话草稿');
            addTearDown(draft.dispose);
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery.withClampedTextScaling(
                  minScaleFactor: scale,
                  maxScaleFactor: scale,
                  child: child!,
                ),
                home: AiPlaybackKeyboardBoundary(
                  enabled: true,
                  child: Scaffold(
                    resizeToAvoidBottomInset: false,
                    body: SafeArea(
                      maintainBottomViewPadding: true,
                      child: AiKeyboardViewport(
                        reservedBottomInset: 20,
                        child: PortraitPlaybackLayout(
                          videoHeightFraction: fraction,
                          video: AspectRatio(
                            aspectRatio: aspectRatio,
                            child: const ColoredBox(
                              key: videoKey,
                              color: Colors.black,
                            ),
                          ),
                          controls: const _InteractiveControls(
                            key: controlsKey,
                          ),
                          panel: ColoredBox(
                            key: panelKey,
                            color: Colors.grey,
                            child: Column(
                              children: [
                                const Expanded(child: SizedBox.expand()),
                                SizedBox(
                                  key: composerKey,
                                  height: 44,
                                  child: TextField(controller: draft),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final video = tester.element(find.byKey(videoKey));
            final controls = tester.element(find.byKey(controlsKey));
            final initialControlRect = _screenRect(
              tester,
              find.byKey(controlsKey),
            );
            final initialVideoHeight = tester
                .getSize(find.byKey(videoKey))
                .height;
            await tester.tap(find.byIcon(Icons.play_arrow));
            await tester.pump();
            expect(find.byIcon(Icons.pause), findsOneWidget);
            expect(tester.takeException(), isNull);

            for (final inset in [80.0, 320.0, 400.0]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              tester.view.padding = const FakeViewPadding(top: 24);
              await tester.pump(const Duration(milliseconds: 16));
              final controlRect = _screenRect(tester, find.byKey(controlsKey));
              final videoRect = _screenRect(tester, find.byKey(videoKey));
              final panelRect = _screenRect(tester, find.byKey(panelKey));
              final buttonRect = _screenRect(tester, find.byType(IconButton));
              final sliderRect = _screenRect(tester, find.byType(Slider));
              expect(
                controlRect.top,
                greaterThanOrEqualTo(videoRect.bottom - .01),
              );
              expect(controlRect.bottom, closeTo(panelRect.top, .01));
              expect(
                buttonRect.top,
                greaterThanOrEqualTo(controlRect.top - .01),
              );
              expect(
                sliderRect.bottom,
                lessThanOrEqualTo(controlRect.bottom + .01),
              );
              expect(
                controlRect.height,
                lessThanOrEqualTo(initialControlRect.height + .01),
              );
              expect(
                controlRect.width,
                lessThanOrEqualTo(initialControlRect.width + .01),
              );
              expect(
                tester.getRect(find.byKey(composerKey)).bottom,
                closeTo(size.height - inset, .01),
              );
              expect(
                tester.getSize(find.byKey(panelKey)).height,
                greaterThan(44),
              );
              expect(tester.element(find.byKey(videoKey)), same(video));
              expect(tester.element(find.byKey(controlsKey)), same(controls));
              expect(find.byIcon(Icons.pause), findsOneWidget);
              expect(draft.text, '保留的对话草稿');
              expect(tester.takeException(), isNull);
            }
            expect(
              _screenRect(tester, find.byKey(controlsKey)).height,
              lessThan(initialControlRect.height),
              reason:
                  'controls themselves must shrink instead of being clipped',
            );
            expect(
              tester.getSize(find.byKey(videoKey)).height,
              lessThan(initialVideoHeight),
            );
            await tester.tap(find.byIcon(Icons.pause));
            await tester.pump();
            expect(find.byIcon(Icons.play_arrow), findsOneWidget);
            final previousProgress = tester
                .widget<Slider>(find.byType(Slider))
                .value;
            await tester.drag(find.byType(Slider), const Offset(60, 0));
            await tester.pumpAndSettle();
            final progress = tester.widget<Slider>(find.byType(Slider)).value;
            expect(progress, greaterThan(previousProgress));
            expect(tester.takeException(), isNull);

            for (final inset in [320.0, 80.0, 0.0]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              tester.view.padding = FakeViewPadding(
                top: 24,
                bottom: inset == 0 ? 20 : 0,
              );
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.takeException(), isNull);
            }
            expect(
              _screenRect(tester, find.byKey(controlsKey)),
              initialControlRect,
            );
            expect(
              tester.getSize(find.byKey(videoKey)).height,
              initialVideoHeight,
            );
            expect(tester.element(find.byKey(videoKey)), same(video));
            expect(tester.element(find.byKey(controlsKey)), same(controls));
            expect(tester.widget<Slider>(find.byType(Slider)).value, progress);
            expect(find.byIcon(Icons.play_arrow), findsOneWidget);
            expect(draft.text, '保留的对话草稿');
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant({
            TargetPlatform.android,
            TargetPlatform.iOS,
          }),
        );
      }
    }
  }

  testWidgets('disabling avoidance keeps the same mounted playing surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, active, child) => AiPlaybackKeyboardBoundary(
            enabled: active,
            child: Scaffold(
              resizeToAvoidBottomInset: !active,
              body: AiKeyboardViewport(enabled: active, child: child!),
            ),
          ),
          child: const SizedBox.expand(key: videoKey),
        ),
      ),
    );
    final surface = tester.element(find.byKey(videoKey));
    final size = tester.getSize(find.byKey(videoKey));
    enabled.value = false;
    await tester.pump();
    expect(tester.element(find.byKey(videoKey)), same(surface));
    expect(tester.getSize(find.byKey(videoKey)), size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation and accessibility media updates remain live', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scale = ValueNotifier(1.0);
    addTearDown(scale.dispose);
    late MediaQueryData seen;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<double>(
          valueListenable: scale,
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(value)),
            child: child!,
          ),
          child: AiPlaybackKeyboardBoundary(
            enabled: true,
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(800, 400);
    scale.value = 1.8;
    await tester.pump();
    expect(seen.size, const Size(800, 400));
    expect(seen.textScaler.scale(10), 18);
  });
}

class _PaintCounter extends CustomPainter {
  _PaintCounter(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

Rect _screenRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

class _InteractiveControls extends StatefulWidget {
  const _InteractiveControls({super.key});

  @override
  State<_InteractiveControls> createState() => _InteractiveControlsState();
}

class _InteractiveControlsState extends State<_InteractiveControls> {
  var _playing = false;
  var _progress = .2;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 80,
    width: double.infinity,
    child: Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _playing = !_playing),
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              const Text('播放'),
            ],
          ),
        ),
        SizedBox(
          height: 32,
          child: Slider(
            value: _progress,
            onChanged: (value) => setState(() => _progress = value),
          ),
        ),
      ],
    ),
  );
}
