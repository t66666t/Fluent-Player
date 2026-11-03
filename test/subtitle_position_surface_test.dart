import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/subtitle_position_surface.dart';

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'visible caption lets $kind reach player buttons and gestures outside its bounds',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 768));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = SubtitlePositionController();
        addTearDown(controller.dispose);
        final entries = ValueNotifier<List<SubtitleOverlayEntry>>(const []);
        addTearDown(entries.dispose);
        var taps = 0, buttons = 0, drags = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    onHorizontalDragUpdate: (_) => drags++,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: TextButton(
                        key: const ValueKey('player-test-button'),
                        onPressed: () => buttons++,
                        child: const Text('设置'),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ValueListenableBuilder<List<SubtitleOverlayEntry>>(
                      valueListenable: entries,
                      builder: (_, value, _) => SubtitleOverlayGroup(
                        entries: value,
                        style: const SubtitleStyle(),
                        alignment: Alignment.bottomCenter,
                        enableDebugPreview: false,
                        positionController: controller,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('player-test-button')),
          kind: kind,
        );
        expect(buttons, 1);
        // A cue can arrive after entry; it must not turn its entire viewport
        // into an invisible input barrier over the controls below it.
        entries.value = const [SubtitleOverlayEntry(text: 'A visible caption')];
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('player-test-button')),
          kind: kind,
          warnIfMissed: false,
        );
        expect(
          buttons,
          2,
          reason: 'subtitle viewport must not cover the player button',
        );
        await tester.tapAt(const Offset(500, 300), kind: kind);
        expect(taps, 1);
        await tester.dragFrom(
          const Offset(400, 300),
          const Offset(100, 0),
          kind: kind,
        );
        expect(drags, greaterThan(0));
        final viewport = tester.renderObject<RenderBox>(
          find.byType(SubtitlePositionViewport),
        );
        final captionPress = await tester.startGesture(
          viewport.localToGlobal(
            controller.geometry.current!.contentRect.center,
          ),
          kind: kind,
        );
        await tester.pump(const Duration(milliseconds: 600));
        await captionPress.up();
        await tester.pump();
        expect(
          controller.editing,
          isFalse,
          reason: 'long presses must not enter subtitle position editing',
        );
        expect(
          taps,
          2,
          reason: 'the caption passes the pointer to the underlying player',
        );
        entries.value = const [];
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('player-test-button')),
          kind: kind,
        );
        expect(buttons, 3);
      },
    );
  }

  testWidgets('dragging moves the caption with the pointer and one frame', (
    tester,
  ) async {
    final SubtitlePositionController controller = SubtitlePositionController();
    addTearDown(controller.dispose);
    int builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: _BuildCounter(
            onBuild: () => builds++,
            child: SubtitleOverlayGroup(
              entries: const [SubtitleOverlayEntry(text: '字幕')],
              style: const SubtitleStyle(),
              alignment: Alignment.center,
              enableDebugPreview: false,
              positionController: controller,
              positionInteractive: true,
              showPositionFrame: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(RichText), findsWidgets);
    final int built = builds;
    final Offset before = tester.getTopLeft(find.byType(RichText).first);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(RichText).first),
    );
    await gesture.moveBy(const Offset(36, -12));
    await tester.pump();
    final Offset after = tester.getTopLeft(find.byType(RichText).first);
    await gesture.up();
    await tester.pump();
    expect(after.dx, closeTo(before.dx + 36, 1.5));
    expect(after.dy, closeTo(before.dy - 12, 1.5));
    expect(builds, built);
    final RenderBox viewport = tester.renderObject<RenderBox>(
      find.byType(SubtitlePositionViewport),
    );
    final Rect content = tester.getRect(find.byType(RichText).first);
    final Offset origin = viewport.localToGlobal(Offset.zero);
    final Rect local = content.shift(-origin);
    final geometry = controller.geometry.current!;
    expect(geometry.contentRect.left, lessThanOrEqualTo(local.left + 1));
    expect(geometry.contentRect.right, greaterThanOrEqualTo(local.right - 1));
    expect(
      geometry.paintRect.width,
      greaterThan(geometry.contentRect.width - 0.1),
    );
  });

  testWidgets('the edit frame does not change the caption rect', (
    tester,
  ) async {
    Future<Rect> rect(bool frame) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const SizedBox(
            width: 400,
            height: 300,
            child: SubtitleOverlayGroup(
              entries: [SubtitleOverlayEntry(text: '字幕位置预览')],
              style: SubtitleStyle(),
              alignment: Alignment.bottomCenter,
              enableDebugPreview: false,
              showPositionFrame: true,
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getRect(find.byType(RichText).first);
    }

    final Rect withFrame = await rect(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: SubtitleOverlayGroup(
            entries: [SubtitleOverlayEntry(text: '字幕位置预览')],
            style: SubtitleStyle(),
            alignment: Alignment.bottomCenter,
            enableDebugPreview: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getRect(find.byType(RichText).first), withFrame);
  });

  testWidgets('a press outside the caption does not start a drag', (
    tester,
  ) async {
    final SubtitlePositionController controller = SubtitlePositionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: SubtitleOverlayGroup(
            entries: const [SubtitleOverlayEntry(text: 'Hi')],
            style: const SubtitleStyle(),
            alignment: Alignment.bottomCenter,
            enableDebugPreview: false,
            positionController: controller,
            positionInteractive: true,
            showPositionFrame: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.startGesture(const Offset(8, 8));
    await tester.pump();
    expect(controller.dragging, isFalse);
  });
}

class _BuildCounter extends StatelessWidget {
  final VoidCallback onBuild;
  final Widget child;

  const _BuildCounter({required this.onBuild, required this.child});

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}
