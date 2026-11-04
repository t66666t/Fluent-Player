import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'video_action_rail_layout.dart';
import 'video_action_rail_motion.dart';

/// Static geometry during motion keeps the library and action cells out of
/// per-frame layout. Only the small action layers change their paint transform.
class VideoActionRail extends StatelessWidget {
  const VideoActionRail({
    super.key,
    required this.layout,
    required this.maxHeight,
    required this.collapsed,
    required this.scrollController,
    required this.actions,
    required this.toggleBuilder,
  });

  final VideoActionRailLayout layout;
  final double maxHeight;
  final bool collapsed;
  final ScrollController scrollController;
  final List<Widget> actions;
  final Widget Function(Animation<double> progress) toggleBuilder;

  @override
  Widget build(BuildContext context) => VideoActionRailMotionBuilder(
    collapsed: collapsed,
    builder: (context, progress, retainActions) {
      final viewportHeight = math.min(
        layout.listHeight,
        math.max(0.0, maxHeight - layout.cellHeight),
      );
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: layout.width,
          maxHeight: maxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (retainActions)
              SizedBox(
                width: layout.width,
                height: viewportHeight,
                child: AbsorbPointer(
                  key: const ValueKey('action-rail-input-guard'),
                  absorbing: collapsed,
                  child: ExcludeSemantics(
                    excluding: collapsed,
                    child: Scrollbar(
                      controller: scrollController,
                      thumbVisibility: viewportHeight + 0.5 < layout.listHeight,
                      thickness: 2,
                      radius: const Radius.circular(2),
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: SingleChildScrollView(
                          key: const ValueKey('action-rail-scroll'),
                          controller: scrollController,
                          primary: false,
                          child: RepaintBoundary(
                            child: Flow(
                              key: const ValueKey('action-rail-grid'),
                              delegate: VideoActionRailFlow(
                                progress: progress,
                                layout: layout,
                              ),
                              children: actions,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            RepaintBoundary(child: toggleBuilder(progress)),
          ],
        ),
      );
    },
  );
}

class VideoActionRailFlow extends FlowDelegate {
  VideoActionRailFlow({required this.progress, required this.layout})
    : super(repaint: progress);

  final Animation<double> progress;
  final VideoActionRailLayout layout;

  @override
  Size getSize(BoxConstraints constraints) =>
      constraints.constrain(Size(layout.width, layout.listHeight));

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size(layout.cellWidth, layout.cellHeight));

  @override
  void paintChildren(FlowPaintingContext context) {
    final rows = layout.rows;
    for (var i = 0; i < context.childCount; i++) {
      final row = i ~/ layout.columns;
      // A small reversible stagger: the row nearest the toggle appears first.
      // Every row is a function of the same progress, without delayed tasks.
      final delay = rows > 1 ? 0.12 * (rows - 1 - row) / (rows - 1) : 0.0;
      final phase = ((progress.value - delay) / (1 - delay)).clamp(0.0, 1.0);
      // Also omit invisible controls from hit testing.
      if (phase == 0) {
        continue;
      }
      final scale = 0.96 + 0.04 * phase;
      final x =
          (i % layout.columns) *
              (layout.cellWidth + VideoActionRailLayout.columnGap) +
          layout.cellWidth * (1 - scale) / 2;
      final y =
          row * (layout.cellHeight + layout.rowGap) +
          math.min(6.0, layout.rowGap) * (1 - phase) +
          layout.cellHeight * (1 - scale) / 2;
      context.paintChild(
        i,
        opacity: phase,
        transform: Matrix4.diagonal3Values(scale, scale, 1)
          ..setTranslationRaw(x, y, 0),
      );
    }
  }

  @override
  bool shouldRelayout(VideoActionRailFlow oldDelegate) =>
      oldDelegate.layout.columns != layout.columns ||
      oldDelegate.layout.cellWidth != layout.cellWidth ||
      oldDelegate.layout.cellHeight != layout.cellHeight ||
      oldDelegate.layout.rowGap != layout.rowGap ||
      oldDelegate.layout.actionCount != layout.actionCount;

  @override
  bool shouldRepaint(VideoActionRailFlow oldDelegate) =>
      oldDelegate.progress != progress || shouldRelayout(oldDelegate);
}
