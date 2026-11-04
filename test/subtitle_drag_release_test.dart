import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  for (final mode in ['original', 'preset', 'ghost']) {
    final preset = mode == 'preset';
    final ghost = mode == 'ghost';
    testWidgets(
      '$mode caption stays at its drop position through delayed commit and every animation frame',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 480));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = SubtitlePositionController();
        addTearDown(controller.dispose);
        final saved = ValueNotifier<SubtitlePlacement>(
          const PresetDefaultPlacement(),
        );
        addTearDown(saved.dispose);
        final commit = Completer<void>();
        addTearDown(() {
          if (!commit.isCompleted) commit.complete();
        });
        controller.beginEditing(
          ghost
              ? const SubtitlePositionTarget.ghost()
              : preset
              ? const SubtitlePositionTarget.preset(
                  channel: SubtitlePositionChannel.video,
                  id: 'release-test',
                )
              : const SubtitlePositionTarget.video(),
        );
        controller.onCommit = (_, placement) async {
          await commit.future;
          saved.value = placement;
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<SubtitlePlacement>(
                valueListenable: saved,
                builder: (_, placement, _) => SubtitleOverlayGroup(
                  entries: const [SubtitleOverlayEntry(text: '字幕拖动测试')],
                  style: const SubtitleStyle(),
                  alignment: placement.alignment ?? Alignment.bottomCenter,
                  isGhostMode: ghost,
                  presetOverride: preset
                      ? const SubtitleDebugPreset(
                          id: 'release-test',
                          name: 'test',
                          category: 'test',
                          description: 'test',
                        )
                      : null,
                  presetPositionOverride: preset && placement.isCustom,
                  enableDebugPreview: false,
                  animateAlignment: true,
                  positionController: controller,
                  positionInteractive: true,
                  showPositionFrame: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final start = controller.geometry.current!.contentRect;
        final pointer = await tester.startGesture(start.center);
        await pointer.moveBy(const Offset(80, -100));
        await tester.pump();
        final dropped = controller.geometry.current!.contentRect;
        expect((dropped.topLeft - start.topLeft).distance, greaterThan(50));
        await pointer.up();
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            (controller.geometry.current!.contentRect.topLeft - dropped.topLeft)
                .distance,
            lessThan(0.1),
            reason:
                'frame $frame must keep the draft while persistence is pending',
          );
        }
        // A quick second contact during a slow save must not discard the
        // settled draft or snap the caption back to its previous alignment.
        await tester.tapAt(dropped.center);
        await tester.pump();
        expect(
          (controller.geometry.current!.contentRect.topLeft - dropped.topLeft)
              .distance,
          lessThan(0.1),
        );
        commit.complete();
        for (var frame = 0; frame < 24; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            (controller.geometry.current!.contentRect.topLeft - dropped.topLeft)
                .distance,
            lessThan(0.1),
            reason:
                'commit handoff frame $frame must not flash or tween from the old position',
          );
        }
        expect(controller.draftOrigin, isNull);
        expect(saved.value.isCustom, isTrue);
      },
    );
  }
}
