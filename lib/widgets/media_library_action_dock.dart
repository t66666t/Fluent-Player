import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Bottom-right sync / more / locate chrome shared by grid cards and list rows.
///
/// Each action gets a square hit target and a centered, quiet glyph.
class MediaLibraryActionDockMetrics {
  static const Color chipColor = Colors.transparent;

  /// Square chip as a fraction of grid card width (preview: 19%).
  static const double gridChipOfWidth = 0.19;

  /// Square chip as a fraction of list row height so a wide row stays compact.
  static const double listChipOfHeight = 0.47;

  static double gridChipSize(double cardWidth) => cardWidth * gridChipOfWidth;

  static double listChipSize(double rowHeight) => rowHeight * listChipOfHeight;

  static double dockWidth({
    required double chipSize,
    required bool showMore,
    required bool showLocate,
    bool showSync = false,
  }) {
    return chipSize *
        ((showMore ? 1 : 0) + (showLocate ? 1 : 0) + (showSync ? 1 : 0));
  }

  /// Trailing inset for bottom meta only. Titles sit above the chip and
  /// must keep full width; a column-wide title inset leaves empty space.
  static double textInset({
    required double chipSize,
    required bool showMore,
    required bool showLocate,
    bool showSync = false,
    double existingPadding = 0,
  }) {
    return math.max(
      0.0,
      dockWidth(
            chipSize: chipSize,
            showMore: showMore,
            showLocate: showLocate,
            showSync: showSync,
          ) -
          existingPadding,
    );
  }
}

/// Flush bottom-right action bar. [more] / [locate] should be hit-only children.
class MediaLibraryActionDock extends StatelessWidget {
  const MediaLibraryActionDock({
    super.key,
    required this.chipSize,
    this.more,
    this.locate,
    this.sync,
  });

  final double chipSize;
  final Widget? more;
  final Widget? locate;
  final Widget? sync;

  bool get _showMore => more != null;
  bool get _showLocate => locate != null;
  bool get _showSync => sync != null;

  @override
  Widget build(BuildContext context) {
    if (!_showMore && !_showLocate && !_showSync) {
      return const SizedBox.shrink();
    }
    final width = MediaLibraryActionDockMetrics.dockWidth(
      chipSize: chipSize,
      showMore: _showMore,
      showLocate: _showLocate,
      showSync: _showSync,
    );
    final radius = BorderRadius.only(topLeft: Radius.circular(chipSize * 0.39));
    return Positioned(
      right: 0,
      bottom: 0,
      child: SizedBox(
        width: width,
        height: chipSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: MediaLibraryActionDockMetrics.chipColor,
            borderRadius: radius,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(child: _glyphs()),
                _hits(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _glyphs() {
    final dots = _MoreDots(chipSize: chipSize);
    final folder = _FolderGlyph(chipSize: chipSize);
    return Row(
      children: [
        if (_showSync)
          Expanded(
            child: Icon(
              Icons.sync_outlined,
              size: chipSize * .56,
              color: AppTokens.text2,
            ),
          ),
        if (_showMore) Expanded(child: Center(child: dots)),
        if (_showLocate) Expanded(child: Center(child: folder)),
      ],
    );
  }

  Widget _hits() {
    return Row(
      children: [
        if (_showSync) Expanded(child: sync!),
        if (_showMore) Expanded(child: more!),
        if (_showLocate)
          Expanded(
            child: KeyedSubtree(
              key: const ValueKey('show-in-parent-folder-button-surface'),
              child: locate!,
            ),
          ),
      ],
    );
  }
}

class _MoreDots extends StatelessWidget {
  const _MoreDots({required this.chipSize});

  final double chipSize;

  @override
  Widget build(BuildContext context) {
    // Filled dots read heavier than a stroked folder, so the cluster is
    // slightly smaller than the icon's layout size.
    final diameter = math.max(1.8, chipSize * 0.10);
    final gap = math.max(1.0, chipSize * 0.065);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Container(
            width: diameter,
            height: diameter,
            decoration: const BoxDecoration(
              color: AppTokens.text3,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

class _FolderGlyph extends StatelessWidget {
  const _FolderGlyph({required this.chipSize});

  final double chipSize;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.folder_open_outlined,
      size: chipSize * 0.56,
      color: AppTokens.text3,
    );
  }
}
