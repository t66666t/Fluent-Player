import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/media_library_view_mode.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'media_library_layout_profile.dart';
import 'media_library_table_row.dart';
import 'media_library_view_defaults.dart';

/// Pinned column header for the details table.
///
/// [width] is the whole scroll pane; the header removes the grid's outer
/// padding itself so its labels sit exactly above the row cells.
class MediaLibraryTableHeader extends StatelessWidget {
  const MediaLibraryTableHeader({
    super.key,
    required this.style,
    required this.width,
  });

  final MediaListStyleSettings style;
  final double width;

  static double _rowWidth(MediaListStyleSettings style, double width) {
    final padding = (style.outerPadding ?? 0).clamp(0.0, width / 4);
    return math.max(0.0, width - padding * 2);
  }

  static double heightFor(
    MediaListStyleSettings style, {
    required double width,
  }) {
    final compact =
        _rowWidth(style, width) <
        MediaLibraryViewDefaults.tableCompactBreakpoint;
    return compact ? 36 : 34;
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();
    final height = heightFor(style, width: width);
    final rowWidth = _rowWidth(style, width);
    final outer = (width - rowWidth) / 2;
    final layout = MediaTableColumnLayout.forWidth(
      width: rowWidth,
      style: style,
    );

    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppTokens.bgBase,
          border: Border(bottom: BorderSide(color: Color(0x1AFFFFFF))),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: outer + layout.horizontalPadding,
          ),
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) {
              final activeKey = settings.mediaTableSort;
              final descending = settings.mediaTableSortDescending;
              if (layout.isCompact) {
                return _CompactHeader(
                  activeKey: activeKey,
                  descending: descending,
                  onSelect: (key, nextDescending) {
                    unawaited(AppHaptics.cardTap(settings));
                    unawaited(
                      settings.setMediaTableSort(
                        key,
                        descending: nextDescending,
                      ),
                    );
                  },
                );
              }

              Widget sortable(
                String label,
                MediaTableSortKey key, {
                Alignment alignment = Alignment.centerLeft,
              }) {
                return _SortableHeaderCell(
                  label: label,
                  sortKey: key,
                  active: activeKey == key,
                  descending: descending,
                  alignment: alignment,
                  onPressed: () =>
                      _cycleSort(settings, key, activeKey, descending),
                );
              }

              return Row(
                children: [
                  Expanded(
                    child: sortable(
                      MediaTableColumnLayout.titleColumnLabel,
                      MediaTableSortKey.title,
                    ),
                  ),
                  for (final column in layout.visibleColumns)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: MediaTableColumnLayout.columnGap,
                      ),
                      child: SizedBox(
                        width: layout.widthFor(column),
                        child: switch (sortKeyForTableColumn(column)) {
                          final key? => sortable(
                            column.label,
                            key,
                            alignment: MediaTableColumnLayout.alignmentFor(
                              column,
                            ),
                          ),
                          null => _StaticHeaderCell(
                            label: column.label,
                            alignment: MediaTableColumnLayout.alignmentFor(
                              column,
                            ),
                          ),
                        },
                      ),
                    ),
                  SizedBox(width: layout.trailingWidth),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Ascending → descending → back to the manual order.
  Future<void> _cycleSort(
    SettingsService settings,
    MediaTableSortKey columnKey,
    MediaTableSortKey activeKey,
    bool descending,
  ) async {
    unawaited(AppHaptics.cardTap(settings));
    if (activeKey != columnKey) {
      await settings.setMediaTableSort(columnKey, descending: false);
    } else if (!descending) {
      await settings.setMediaTableSort(columnKey, descending: true);
    } else {
      await settings.setMediaTableSort(MediaTableSortKey.manual);
    }
  }
}

const _headerTextSize = 12.0;

class _StaticHeaderCell extends StatelessWidget {
  const _StaticHeaderCell({required this.label, required this.alignment});

  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppTokens.text3,
          fontSize: _headerTextSize,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SortableHeaderCell extends StatefulWidget {
  const _SortableHeaderCell({
    required this.label,
    required this.sortKey,
    required this.active,
    required this.descending,
    required this.onPressed,
    this.alignment = Alignment.centerLeft,
  });

  final String label;
  final MediaTableSortKey sortKey;
  final bool active;
  final bool descending;
  final VoidCallback onPressed;
  final Alignment alignment;

  @override
  State<_SortableHeaderCell> createState() => _SortableHeaderCellState();
}

class _SortableHeaderCellState extends State<_SortableHeaderCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final color = widget.active
        ? AppTokens.text1
        : _hovered
        ? AppTokens.text2
        : AppTokens.text3;
    // The arrow is laid out even when hidden so labels never shift sideways
    // as the sort changes.
    final arrow = AnimatedOpacity(
      duration: motion,
      curve: Curves.easeOutCubic,
      opacity: widget.active ? 1 : (_hovered ? 0.35 : 0),
      child: AnimatedRotation(
        duration: motion,
        curve: Curves.easeOutCubic,
        turns: widget.active && widget.descending ? 0.5 : 0,
        child: Icon(
          Icons.arrow_upward_rounded,
          size: 13,
          color: widget.active ? AppTokens.accent : AppTokens.text3,
        ),
      ),
    );
    final label = Flexible(
      child: AnimatedDefaultTextStyle(
        duration: motion,
        curve: Curves.easeOutCubic,
        // Merge so the inherited font family survives.
        style: DefaultTextStyle.of(context).style.merge(
          TextStyle(
            color: color,
            fontSize: _headerTextSize,
            fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final rightAligned = widget.alignment == Alignment.centerRight;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: ValueKey('media-table-header-${widget.sortKey.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Align(
          alignment: widget.alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: rightAligned
                ? [arrow, const SizedBox(width: 3), label]
                : [label, const SizedBox(width: 3), arrow],
          ),
        ),
      ),
    );
  }
}

/// Narrow panes have no column labels; a single sort pill replaces them.
class _CompactHeader extends StatelessWidget {
  const _CompactHeader({
    required this.activeKey,
    required this.descending,
    required this.onSelect,
  });

  final MediaTableSortKey activeKey;
  final bool descending;
  final void Function(MediaTableSortKey key, bool descending) onSelect;

  static String _keyLabel(MediaTableSortKey key) => switch (key) {
    MediaTableSortKey.manual => '手动顺序',
    MediaTableSortKey.title => MediaTableColumnLayout.titleColumnLabel,
    MediaTableSortKey.type => MediaTableColumn.type.label,
    MediaTableSortKey.duration => MediaTableColumn.duration.label,
    MediaTableSortKey.progress => MediaTableColumn.progress.label,
    MediaTableSortKey.updated => MediaTableColumn.updated.label,
  };

  @override
  Widget build(BuildContext context) {
    final current = activeKey == MediaTableSortKey.manual
        ? _keyLabel(activeKey)
        : '${_keyLabel(activeKey)} ${descending ? '↓' : '↑'}';
    return Row(
      children: [
        const Text(
          '排序',
          style: TextStyle(color: AppTokens.text3, fontSize: _headerTextSize),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<(MediaTableSortKey, bool)>(
          key: const ValueKey('media-table-sort-menu'),
          tooltip: '排序方式',
          color: AppTokens.bgOverlay,
          position: PopupMenuPosition.under,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTokens.lineSubtle),
          ),
          onSelected: (choice) => onSelect(choice.$1, choice.$2),
          itemBuilder: (context) => [
            for (final key in MediaTableSortKey.values)
              if (key == MediaTableSortKey.manual)
                _item(key, false, '手动顺序')
              else ...[
                _item(key, false, '${_keyLabel(key)} 升序'),
                _item(key, true, '${_keyLabel(key)} 降序'),
              ],
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current,
                  style: const TextStyle(
                    color: AppTokens.text1,
                    fontSize: _headerTextSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: AppTokens.text2,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<(MediaTableSortKey, bool)> _item(
    MediaTableSortKey key,
    bool itemDescending,
    String label,
  ) {
    final selected =
        key == activeKey &&
        (key == MediaTableSortKey.manual || itemDescending == descending);
    return PopupMenuItem(
      value: (key, itemDescending),
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? AppTokens.text1 : AppTokens.text2,
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (selected)
            const Icon(Icons.check_rounded, size: 18, color: AppTokens.accent),
        ],
      ),
    );
  }
}
