import 'package:flutter/material.dart';

@immutable
class AdaptiveSettingsDialogMetrics {
  const AdaptiveSettingsDialogMetrics._({
    required this.dialogWidth,
    required this.dialogMaxHeight,
    required this.contentMaxHeight,
    required this.insetPadding,
    required this.titlePadding,
    required this.contentPadding,
    required this.actionsPadding,
    required this.gap,
    required this.titleSize,
    required this.bodySize,
    required this.captionSize,
    required this.isCompact,
    required this.useTwoColumns,
  });

  factory AdaptiveSettingsDialogMetrics.fromSize(
    Size screen, {
    double preferredWidth = 700,
  }) {
    final compact = screen.height < 520;
    final horizontalInset = screen.width < 600 ? 12.0 : 24.0;
    final verticalInset = compact ? 8.0 : (screen.height < 760 ? 16.0 : 24.0);
    final availableWidth = (screen.width - horizontalInset * 2).clamp(
      0.0,
      double.infinity,
    );
    final dialogWidth = availableWidth.clamp(0.0, preferredWidth).toDouble();
    final dialogMaxHeight = (screen.height - verticalInset * 2)
        .clamp(0.0, screen.height)
        .toDouble();
    final verticalChrome = compact ? 96.0 : 116.0;
    final rawContentHeight = dialogMaxHeight - verticalChrome;
    final contentMaxHeight = dialogMaxHeight <= 80
        ? dialogMaxHeight
        : rawContentHeight.clamp(80.0, dialogMaxHeight).toDouble();

    return AdaptiveSettingsDialogMetrics._(
      dialogWidth: dialogWidth,
      dialogMaxHeight: dialogMaxHeight,
      contentMaxHeight: contentMaxHeight,
      insetPadding: EdgeInsets.symmetric(
        horizontal: horizontalInset,
        vertical: verticalInset,
      ),
      titlePadding: EdgeInsets.fromLTRB(
        compact ? 14 : 20,
        compact ? 10 : 16,
        compact ? 14 : 20,
        compact ? 4 : 8,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        compact ? 12 : 20,
        compact ? 4 : 8,
        compact ? 12 : 20,
        compact ? 4 : 8,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        compact ? 8 : 12,
        compact ? 2 : 4,
        compact ? 8 : 12,
        compact ? 6 : 10,
      ),
      gap: compact ? 6 : 10,
      titleSize: compact ? 16 : 18,
      bodySize: compact ? 12 : 13,
      captionSize: compact ? 10 : 11,
      isCompact: compact,
      useTwoColumns: dialogWidth >= 620,
    );
  }

  final double dialogWidth;
  final double dialogMaxHeight;
  final double contentMaxHeight;
  final EdgeInsets insetPadding;
  final EdgeInsets titlePadding;
  final EdgeInsets contentPadding;
  final EdgeInsets actionsPadding;
  final double gap;
  final double titleSize;
  final double bodySize;
  final double captionSize;
  final bool isCompact;
  final bool useTwoColumns;
}

class AdaptiveSettingsDialogTheme extends StatelessWidget {
  const AdaptiveSettingsDialogTheme({
    super.key,
    required this.metrics,
    required this.child,
  });

  final AdaptiveSettingsDialogMetrics metrics;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: metrics.isCompact
            ? const VisualDensity(horizontal: -2, vertical: -3)
            : const VisualDensity(horizontal: -1, vertical: -2),
        listTileTheme: base.listTileTheme.copyWith(
          dense: true,
          minVerticalPadding: metrics.isCompact ? 2 : 4,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: metrics.bodySize,
          ),
          subtitleTextStyle: TextStyle(
            color: Colors.white54,
            fontSize: metrics.captionSize,
            height: 1.25,
          ),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: metrics.isCompact ? 9 : 12,
            vertical: metrics.isCompact ? 8 : 10,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// Places setting tiles in one column on narrow screens and two balanced
/// columns when the dialog has enough room. Tile heights remain content-driven
/// so translated or accessibility-scaled labels are never clipped.
class AdaptiveSettingsTileGrid extends StatelessWidget {
  const AdaptiveSettingsTileGrid({
    super.key,
    required this.children,
    required this.gap,
  });

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 2 : 1;
        final itemWidth = columns == 2
            ? (constraints.maxWidth - gap) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: 0,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
