import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/subtitle_position_hint.dart';

void main() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      'tapping exit hint with $kind ends editing and restores playback input',
      (tester) async {
        final controller = SubtitlePositionController();
        addTearDown(controller.dispose);
        controller.beginEditing(const SubtitlePositionTarget.video());
        var editing = true;
        var playerTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => playerTaps++,
                    ),
                    SubtitleOverlayGroup(
                      entries: const [SubtitleOverlayEntry(text: 'Caption')],
                      style: const SubtitleStyle(),
                      alignment: Alignment.bottomCenter,
                      enableDebugPreview: false,
                      positionController: controller,
                      positionInteractive: editing,
                      showPositionFrame: editing,
                    ),
                    if (editing)
                      Positioned(
                        top: 20,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: SubtitlePositionHint(
                            onExit: () {
                              controller.endEditing();
                              setState(() => editing = false);
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('拖拽调整位置 (点击退出)'), findsOneWidget);
        // The padding is part of the target, not only the text's glyphs.
        final hint = tester.getRect(find.byType(SubtitlePositionHint));
        await tester.tapAt(Offset(hint.left + 8, hint.center.dy), kind: kind);
        await tester.pumpAndSettle();
        expect(controller.editing, isFalse);
        expect(find.byType(SubtitlePositionHint), findsNothing);
        expect(playerTaps, 0);
        await tester.tapAt(
          controller.geometry.current!.contentRect.center,
          kind: kind,
        );
        expect(playerTaps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
