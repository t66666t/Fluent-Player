import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_display_state.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';
import 'package:video_player_app/widgets/subtitle_display_layer.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List imageBytes;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 240, 60),
      ui.Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 60);
    imageBytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });

  for (final size in [const Size(390, 720), const Size(720, 390)]) {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      for (final mode in [
        'original',
        'preset',
        'ghost',
        'preview',
        'standalone',
        'image',
      ]) {
        testWidgets(
          '$mode passes overlapping player input through at $size with $kind',
          (tester) async {
            await tester.binding.setSurfaceSize(size);
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final controller = SubtitlePositionController();
            addTearDown(controller.dispose);
            final display = ValueNotifier(
              const SubtitleDisplayState(
                entries: [
                  SubtitleOverlayEntry(
                    text: 'Caption over controls',
                    secondaryText: 'Secondary caption',
                  ),
                ],
              ),
            );
            final showButton = ValueNotifier(true);
            addTearDown(display.dispose);
            addTearDown(showButton.dispose);
            var buttons = 0, taps = 0, doubleTaps = 0, longPresses = 0;
            var horizontalDrags = 0, verticalDrags = 0;
            Widget overlay;
            if (mode == 'preview') {
              overlay = SubtitleDisplayLayer(
                notifier: display,
                alignment: Alignment.center,
                style: const SubtitleStyle(),
                positionController: controller,
              );
            } else if (mode == 'standalone' || mode == 'image') {
              overlay = Center(
                child: SizedBox(
                  width: 280,
                  height: 80,
                  child: SubtitleOverlay(
                    text: mode == 'image' ? '' : 'Caption over controls',
                    image: mode == 'image' ? imageBytes : null,
                  ),
                ),
              );
            } else {
              overlay = SubtitleOverlayGroup(
                entries: display.value.entries,
                style: const SubtitleStyle(),
                alignment: Alignment.center,
                enableDebugPreview: false,
                isGhostMode: mode == 'ghost',
                presetOverride: mode == 'preset'
                    ? const SubtitleDebugPreset(
                        id: 'input-test',
                        name: 'test',
                        category: 'test',
                        description: 'test',
                        bottom: 0,
                      )
                    : null,
                presetPositionOverride: mode == 'preset',
                positionController: controller,
              );
            }
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => taps++,
                        onDoubleTap: () => doubleTaps++,
                        onLongPress: () => longPresses++,
                        onHorizontalDragUpdate: (_) => horizontalDrags++,
                        onVerticalDragUpdate: (_) => verticalDrags++,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: showButton,
                          builder: (_, visible, _) => Center(
                            child: visible
                                ? IconButton(
                                    key: const ValueKey('fullscreen'),
                                    onPressed: () => buttons++,
                                    icon: const Icon(Icons.fullscreen),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      overlay,
                    ],
                  ),
                ),
              ),
            );
            if (mode == 'image') {
              await tester.runAsync(() async {
                await precacheImage(
                  MemoryImage(imageBytes),
                  tester.element(find.byType(SubtitleOverlay)),
                );
              });
              // The subtitle decodes intrinsic dimensions separately from
              // Flutter's image cache. Wait for that native decode as well.
              for (
                var attempt = 0;
                find.byType(Image).evaluate().isEmpty && attempt < 20;
                attempt++
              ) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
                await tester.pump();
              }
            }
            await tester.pumpAndSettle();
            final button = find.byKey(const ValueKey('fullscreen'));
            final point = tester.getCenter(button);
            final Rect captionRect = mode == 'image'
                ? tester.getRect(find.byType(Image))
                : mode == 'standalone'
                ? tester.getRect(find.byType(SubtitleOverlay))
                : controller.geometry.current!.contentRect;
            expect(
              captionRect.contains(point),
              isTrue,
              reason: 'the caption must actually overlap the player control',
            );
            await tester.tap(button, kind: kind);
            await tester.pump(kDoubleTapTimeout);
            await tester.pumpAndSettle();
            expect(buttons, 1);
            expect(taps, 0);
            showButton.value = false;
            await tester.pump();
            await tester.tapAt(point, kind: kind);
            await tester.pump(kDoubleTapTimeout);
            expect(taps, 1);
            await tester.tapAt(point, kind: kind);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tapAt(point, kind: kind);
            await tester.pump(kDoubleTapTimeout);
            expect(doubleTaps, 1);
            final press = await tester.startGesture(point, kind: kind);
            await tester.pump(const Duration(milliseconds: 600));
            await press.up();
            await tester.pump();
            expect(longPresses, 1);
            expect(controller.editing, isFalse);
            await tester.dragFrom(point, const Offset(60, 0), kind: kind);
            await tester.dragFrom(point, const Offset(0, -60), kind: kind);
            await tester.pumpAndSettle();
            expect(horizontalDrags, greaterThan(0));
            expect(verticalDrags, greaterThan(0));
            expect(controller.dragging, isFalse);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
