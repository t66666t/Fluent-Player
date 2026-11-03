import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import 'media_library_layout_profile.dart';
import 'playback_source_viewport.dart';
import 'visibility_input_gate.dart';

/// Narrowest a Bilibili list row (cover, title, import button) gets before
/// the list drops a column.
const double kBilibiliListMinTileWidth = 460;

/// Most columns a Bilibili list uses, as the media library's widest list
/// default.
const int kBilibiliListMaxColumns = 4;

/// Column gap of a multi-column Bilibili list: the media library's list
/// spacing, as a share of the cell width, with no outer padding (the rows
/// keep their own).
const double kBilibiliListSpacingScale =
    MediaLibraryLayoutDefaults.defaultListSpacingScale;

MediaLibraryWidthDistribution _distribute(double width, int columns) =>
    MediaLibraryLayoutDefaults.distributeWidth(
      availableWidth: width,
      columns: columns,
      spacingScale: kBilibiliListSpacingScale,
      paddingScale: 0,
    );

/// How many columns a Bilibili list [width] wide shows: one on phones and
/// narrow windows (the plain list), more as the window gets wider, each at
/// least [kBilibiliListMinTileWidth] wide.
int bilibiliListColumns(double width) {
  if (!width.isFinite || width <= 0) return 1;
  for (var columns = kBilibiliListMaxColumns; columns > 1; columns--) {
    if (_distribute(width, columns).cellWidth >= kBilibiliListMinTileWidth) {
      return columns;
    }
  }
  return 1;
}

/// A Bilibili result list that turns into a grid of rows on wide windows.
///
/// With one column it is the plain [ListView] the pages always showed. Wider
/// windows lay the same rows out in [bilibiliListColumns] columns, spaced
/// as the media library's list grid, with [footer] (loading more, retry,
/// end of list) across the full width. When the column count changes while
/// the window is resized, the list stays near the rows it showed.
class BilibiliAdaptiveList extends StatefulWidget {
  const BilibiliAdaptiveList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.footer,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.animateItems = false,
    this.itemKey,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Object Function(int index)? itemKey;

  /// Shown after the last row, across the full width.
  final WidgetBuilder? footer;

  final ScrollController? controller;
  final EdgeInsets padding;

  /// Briefly reveals newly received rows. Rows first built later by scrolling
  /// are shown immediately, and returning to a row never replays its entrance.
  final bool animateItems;

  @override
  State<BilibiliAdaptiveList> createState() => _BilibiliAdaptiveListState();
}

class _BilibiliAdaptiveListState extends State<BilibiliAdaptiveList> {
  ScrollController? _own;
  int? _columns;
  final Set<int> _built = <int>{};
  int _firstNewIndex = 0;
  Duration _arrivedAt = SchedulerBinding.instance.currentFrameTimeStamp;

  ScrollController get _controller =>
      widget.controller ?? (_own ??= PlaybackScrollController());

  @override
  void didUpdateWidget(BilibiliAdaptiveList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != oldWidget.itemCount) {
      _firstNewIndex = widget.itemCount > oldWidget.itemCount
          ? oldWidget.itemCount
          : 0;
      _arrivedAt = SchedulerBinding.instance.currentFrameTimeStamp;
      if (widget.itemCount < oldWidget.itemCount) _built.clear();
    }
  }

  Widget _buildItem(BuildContext context, int index) {
    final child = widget.itemBuilder(context, index);
    if (!widget.animateItems) return child;
    final firstBuild = _built.add(index);
    final age = SchedulerBinding.instance.currentFrameTimeStamp - _arrivedAt;
    final animate =
        firstBuild &&
        index >= _firstNewIndex &&
        index < _firstNewIndex + 16 &&
        age <= const Duration(milliseconds: 350) &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Interval(
        ((index - _firstNewIndex).clamp(0, 5)) * .035,
        1,
        curve: Curves.easeOutCubic,
      ),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: VisibilityInputGate(
          enabled: (value * 255).round() > 0,
          child: Transform.translate(
            offset: Offset(0, 4 * (1 - value)),
            child: child!,
          ),
        ),
      ),
      child: RepaintBoundary(child: child),
    );
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  /// Capture the old row geometry before building the new grouping.
  void _columnsChanged(int from, int to) {
    PlaybackScrollController.preserveForRelayout(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - widget.padding.horizontal;
        final columns = bilibiliListColumns(width);
        final before = _columns;
        _columns = columns;
        if (before != null && before != columns) {
          _columnsChanged(before, columns);
        }
        final footer = widget.footer;
        final count = widget.itemCount;
        if (columns == 1) {
          return PlaybackListView.builder(
            itemKey: widget.itemKey ?? (index) => index,
            anchorItemCount: count,
            controller: _controller,
            padding: widget.padding,
            itemCount: count + (footer == null ? 0 : 1),
            itemBuilder: (context, index) =>
                index < count ? _buildItem(context, index) : footer!(context),
          );
        }
        final cells = _distribute(width, columns);
        final rows = (count + columns - 1) ~/ columns;
        // The same list as with one column, so the scroll position stays.
        return PlaybackListView.builder(
          itemKey: widget.itemKey ?? (index) => index,
          anchorItemCount: count,
          columns: columns,
          controller: _controller,
          padding: widget.padding,
          itemCount: rows + (footer == null ? 0 : 1),
          itemBuilder: (context, row) {
            if (row >= rows) return footer!(context);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) SizedBox(width: cells.crossSpacing),
                  SizedBox(
                    width: cells.cellWidth,
                    child: row * columns + column < count
                        ? _buildItem(context, row * columns + column)
                        : null,
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
